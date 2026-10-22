# frozen_string_literal: true

module IsbfAlumni
  class InitialPasswordsController < ::ApplicationController
    requires_plugin "isbf-alumni"
    requires_login

    def update
      raise Discourse::InvalidAccess unless IsbfAlumni.available? &&
        SiteSetting.enable_local_logins && !SiteSetting.enable_discourse_connect

      RateLimiter.new(current_user, "isbf-alumni-initial-password", 10, 10.minutes, apply_limit_to_staff: true).performed!
      application = Application.find_by(user_id: current_user.id)
      raise Discourse::InvalidAccess unless application

      password = params[:password]
      unless password.is_a?(String) && password.length <= User.max_password_length
        return render_json_error(I18n.t("isbf_alumni.initial_password_invalid"), status: 422)
      end

      password_created = false
      application.with_lock do
        current_user.with_lock do
          user = current_user
          unless application.status == "registered" && application.user_id == user.id &&
              application.registered_at.present? && application.email_verified_at.present? &&
              application.email.casecmp?(user.email.to_s) && user.active? && user.guardian.can_access_forum? &&
              !user.staged? && !user.suspended? && !user.silenced? && user.id.positive? &&
              IsbfAlumni.member?(user)
            raise Discourse::InvalidAccess
          end

          if user.has_password?
            unless user.confirm_password?(password)
              return render_json_error(I18n.t("isbf_alumni.initial_password_already_set"), status: 409)
            end
          else
            user.password = password
            user.password_required!
            user.save!
            password_created = true
          end
        end
      end

      if password_created
        reset_csrf_token(request)
        log_on_user(current_user)
      end

      render json: success_json
    rescue ActiveRecord::RecordInvalid => error
      render_json_error(error.record, status: 422)
    end
  end
end
