# frozen_string_literal: true

require "digest"
require "openssl"
require "securerandom"
require "uri/mailto"

module IsbfAlumni
  class RegistrationError < StandardError
    attr_reader :key

    def initialize(key)
      @key = key
      super(I18n.t("isbf_alumni.errors.#{key}"))
    end
  end

  module Registration
    VERIFY_TTL = 15.minutes.to_i
    SESSION_TTL = 24.hours.to_i
    INVITE_TTL = 7.days
    PROFILE_FIELDS = %w[country_code region_code city_code city_name industry bio visible].freeze

    class << self
      def enabled?
        IsbfAlumni.available? && SiteSetting.isbf_alumni_registration_enabled &&
          SiteSetting.respond_to?(:academy_roles_enabled) && SiteSetting.academy_roles_enabled &&
          !!defined?(DiscourseAcademyRoles::StudentInviteExtension)
      end

      def ensure_enabled!
        raise Discourse::InvalidAccess unless enabled?
      end

      def reviewer?(user)
        return false unless IsbfAlumni.available? && user && !user.suspended? && !user.silenced?
        return true if user[:admin]
        defined?(DiscourseAcademyRoles::ModeratorPermissions) &&
          DiscourseAcademyRoles::ModeratorPermissions::SETTINGS.key?(:review_alumni) &&
          DiscourseAcademyRoles::ModeratorPermissions.allowed?(user, :review_alumni)
      end

      def request_code(email:, session:, ip:)
        ensure_enabled!
        email = normalize_email(email)
        RateLimiter.new(nil, "isbf-alumni-email-ip-#{digest(ip)}", 10, 1.hour).performed!
        RateLimiter.new(nil, "isbf-alumni-email-#{digest(email)}", 3, 15.minutes).performed!
        previous = session.delete(:isbf_alumni_challenge)
        Discourse.redis.del(challenge_key(previous)) if previous.present?
        session.delete(:isbf_alumni_verified)
        nonce = SecureRandom.hex(24)
        code = format("%06d", SecureRandom.random_number(1_000_000))
        eligible = User.real.where(staged: false).find_by_email(email).blank? && !ScreenedEmail.should_block?(email)
        data = {
          email: email,
          code_digest: digest("#{nonce}:#{code}"),
          encrypted_code: encryptor.encrypt_and_sign(code),
          eligible: eligible,
        }
        Discourse.redis.setex(challenge_key(nonce), VERIFY_TTL, data.to_json)
        session[:isbf_alumni_challenge] = nonce
        Jobs.enqueue(:isbf_alumni_verification_email, challenge_id: nonce)
        true
      end

      def verify_code(code:, session:)
        ensure_enabled!
        nonce = session[:isbf_alumni_challenge]
        raise RegistrationError.new(:invalid_code) unless nonce.present? && code.is_a?(String) && code.match?(/\A\d{6}\z/)
        attempts_key = "#{challenge_key(nonce)}:attempts"
        attempts = Discourse.redis.incr(attempts_key)
        Discourse.redis.expire(attempts_key, VERIFY_TTL)
        data = challenge(nonce)
        valid = attempts <= 5 && data && data["eligible"] &&
          ActiveSupport::SecurityUtils.secure_compare(data.fetch("code_digest"), digest("#{nonce}:#{code}"))
        raise RegistrationError.new(:invalid_code) unless valid
        application = Application.find_or_create_by!(email: data.fetch("email")) do |record|
          record.email_verified_at = Time.current
        end
        application.update!(email_verified_at: Time.current)
        session[:isbf_alumni_verified] = { "id" => application.id, "at" => Time.current.to_i }
        session.delete(:isbf_alumni_challenge)
        Discourse.redis.del(challenge_key(nonce), attempts_key)
        application
      end

      def current_application(session)
        owner = session[:isbf_alumni_verified]
        unless owner.is_a?(Hash) && owner["at"].to_i >= Time.current.to_i - SESSION_TTL
          raise Discourse::InvalidAccess
        end
        Application.find(owner["id"])
      rescue ActiveRecord::RecordNotFound
        raise Discourse::InvalidAccess
      end

      def submit!(application, attributes)
        ensure_enabled!
        input = attributes.to_h.stringify_keys
        application.with_lock do
          next application if application.status == "pending"
          raise RegistrationError.new(:application_locked) unless application.editable?
          raise RegistrationError.new(:email_registered) if existing_user?(application.email)
          name = IsbfAlumni.text(input["real_name"], 80, required: true)
          year = Integer(input["graduation_year"], exception: false)
          raise RegistrationError.new(:invalid_year) unless year && (1900..Time.zone.today.year).cover?(year)
          profile = normalized_profile(input)
          ids = input["proof_ids"]
          valid_ids = ids.is_a?(Array) && ids.length.between?(1, 5) && ids.uniq == ids &&
            ids.all? do |id|
              proof = application.proofs.find { |item| item["id"] == id && item["removed_at"].blank? }
              proof && File.file?(Proofs.path(id))
            end
          raise RegistrationError.new(:invalid_proof) unless valid_ids
          proofs = application.proofs.map { |proof| ids.include?(proof["id"]) ? proof.merge("bound" => true) : proof }
          snapshot = {
            "real_name" => name, "graduation_year" => year, "profile" => profile,
            "proof_ids" => ids, "submitted_at" => Time.current.iso8601,
          }
          application.update!(
            real_name: name, graduation_year: year, profile: profile,
            proofs: proofs, submitted_proof_ids: ids, submitted_at: Time.current,
            status: "pending", rejection_reason: nil, mail_status: "none",
            submissions: application.submissions + [snapshot],
          )
          reviewable = application.reviewable
          if reviewable
            reviewable.transition_to(:pending, Discourse.system_user)
            reviewable.update!(force_review: true)
          else
            reviewable = ReviewableIsbfAlumni.needs_review!(
              created_by: Discourse.system_user,
              reviewable_by_moderator: true,
              potential_spam: false,
              payload: { "application_id" => application.id },
            )
            reviewable.update!(force_review: true)
            application.update!(reviewable: reviewable)
          end
          application
        end
      end

      def approve!(application, reviewer)
        raise Discourse::InvalidAccess unless reviewer?(reviewer)
        application.with_lock do
          raise RegistrationError.new(:application_locked) unless application.status == "pending"
          raise RegistrationError.new(:email_registered) if existing_user?(application.email)
          application.update!(status: "approved", reviewed_by: reviewer, reviewed_at: Time.current)
          issue_invite!(application)
          queue_decision!(application)
        end
      end

      def reject!(application, reviewer, reason)
        raise Discourse::InvalidAccess unless reviewer?(reviewer)
        reason = IsbfAlumni.text(reason, 2000, required: true)
        application.with_lock do
          raise RegistrationError.new(:application_locked) unless application.status == "pending"
          application.update!(status: "rejected", rejection_reason: reason, reviewed_by: reviewer, reviewed_at: Time.current)
          queue_decision!(application)
        end
      end

      def resend!(application)
        ensure_enabled!
        RateLimiter.new(nil, "isbf-alumni-resend-#{application.id}", 3, 1.hour).performed!
        application.with_lock do
          next unless application.status.in?(%w[approved rejected])
          if application.status == "approved"
            raise RegistrationError.new(:email_registered) if existing_user?(application.email)
            issue_invite!(application) unless application.mail_status == "failed" && application.invite&.redeemable?
          end
          queue_decision!(application)
        end
      end

      def bound_invite?(invite)
        return false unless IsbfAlumni.available? && invite && invite.domain.blank? &&
          invite.max_redemptions_allowed == 1 && !invite.admin? && !invite.moderator?
        application =
          if invite.persisted?
            Application.find_by(invite_id: invite.id)
          elsif invite.respond_to?(:isbf_alumni_application_id)
            Application.find_by(id: invite.isbf_alumni_application_id)
          end
        application && application.status == "approved" && application.email_verified_at.present? &&
          application.user_id.nil? && application.registered_at.nil? &&
          normalize_email(invite.email) == application.email
      rescue RegistrationError
        false
      end

      def redeem(invite:, email:, redeeming_user:)
        application = Application.find_by(invite_id: invite.id)
        raise Discourse::InvalidAccess unless application && redeeming_user.blank?
        application.with_lock do
          raise Discourse::InvalidAccess unless bound_invite?(invite) && invite.redeemable? && normalize_email(email) == application.email
          raise Invite::UserExists, I18n.t("isbf_alumni.errors.email_registered") if existing_user?(application.email)
          user = yield
          raise ActiveRecord::RecordNotSaved unless user && normalize_email(user.email) == application.email
          IsbfAlumni.group.add(user)
          IsbfAlumni.import_registration_profile!(user, application.profile)
          if application.profile["visible"] == true
            user.upsert_custom_fields(IsbfAlumni::VISIBLE_FIELD => "true")
          end
          application.update!(status: "registered", user: user, registered_at: Time.current)
          user
        end
      end

      def challenge(nonce)
        return unless nonce.is_a?(String) && nonce.match?(/\A[0-9a-f]{48}\z/)
        raw = Discourse.redis.get(challenge_key(nonce))
        JSON.parse(raw) if raw
      end

      def verification_code(data)
        encryptor.decrypt_and_verify(data.fetch("encrypted_code"))
      end

      def normalized_profile(input)
        IsbfAlumni.normalize_location(input, required: false).stringify_keys.merge(
          "industry" => IsbfAlumni.text(input["industry"], 60, required: false),
          "bio" => IsbfAlumni.text(input["bio"], 500, required: false),
          "visible" => input.key?("visible") ? IsbfAlumni.boolean(input["visible"]) : false,
        )
      end

      private

      def normalize_email(email)
        value = email.is_a?(String) ? email.strip.downcase : ""
        raise RegistrationError.new(:invalid_email) unless value.length <= 254 && URI::MailTo::EMAIL_REGEXP.match?(value)
        value
      end

      def existing_user?(email)
        User.real.where(staged: false).find_by_email(email).present?
      end

      def digest(value)
        OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, value.to_s)
      end

      def challenge_key(nonce)
        "isbf-alumni:verification:#{nonce}"
      end

      def encryptor
        @encryptor ||= ActiveSupport::MessageEncryptor.new(
          Rails.application.key_generator.generate_key("isbf-alumni-verification", 32),
          cipher: "aes-256-gcm",
        )
      end

      def issue_invite!(application)
        application.invite&.update!(invalidated_at: Time.current)
        invite = Invite.new(
          email: application.email, invited_by: Discourse.system_user,
          max_redemptions_allowed: 1, expires_at: Time.current + INVITE_TTL,
          emailed_status: Invite.emailed_status_types[:not_required],
        )
        invite.isbf_alumni_application_id = application.id
        invite.save!
        application.update!(invite: invite)
      end

      def queue_decision!(application)
        application.update!(mail_status: "pending", mail_version: application.mail_version + 1)
      end
    end
  end
end
