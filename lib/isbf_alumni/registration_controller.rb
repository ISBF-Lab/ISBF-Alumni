# frozen_string_literal: true

module IsbfAlumni
  class RegistrationController < ::ApplicationController
    requires_plugin "isbf-alumni"
    skip_before_action :redirect_to_login_if_required, raise: false
    skip_before_action :check_xhr, only: :proof
    before_action :set_private_headers
    before_action :ensure_registration, except: :proof
    before_action :ensure_new_account, except: %i[configuration proof]

    rescue_from RegistrationError do |error|
      render_json_error(error.message, status: error.key == :application_locked ? 409 : 422)
    end

    def configuration
      render json: {
        enabled: Registration.enabled?,
        countries: Geography.registration_catalog,
        proof_max_count: Proofs::MAX_COUNT,
        proof_source_max_bytes: Proofs::SOURCE_MAX_BYTES,
        proof_max_bytes: Proofs::MAX_BYTES,
      }
    end

    def email
      Registration.request_code(email: params[:email], session: session, ip: request.remote_ip)
      render json: success_json
    end

    def verify_email
      application = Registration.verify_code(code: params[:code], session: session)
      render json: owner_status(application)
    end

    def current
      application = Registration.current_application(session)
      render json: owner_status(application)
    rescue Discourse::InvalidAccess
      render json: { verified: false }
    end

    def submit
      application = Registration.current_application(session)
      RateLimiter.new(nil, "isbf-alumni-submit-#{application.id}", 5, 1.hour).performed!
      input = params.permit(:real_name, :graduation_year, *Registration::PROFILE_FIELDS, proof_ids: []).to_h
      application = Registration.submit!(application, input)
      render json: { application: application.public_status }
    rescue Discourse::InvalidParameters
      render_json_error(I18n.t("isbf_alumni.errors.invalid_profile"), status: 422)
    end

    def upload
      application = Registration.current_application(session)
      RateLimiter.new(nil, "isbf-alumni-proof-#{application.id}", 10, 1.hour).performed!
      RateLimiter.new(nil, "isbf-alumni-proof-ip-#{Digest::SHA256.hexdigest(request.remote_ip)}", 30, 1.hour).performed!
      render json: Proofs.upload!(application, params[:file])
    end

    def remove_proof
      application = Registration.current_application(session)
      Proofs.remove!(application, params[:id])
      render json: success_json
    end

    def proof
      id = params[:id].to_s
      raise Discourse::NotFound unless Proofs.valid_id?(id)
      application =
        if Registration.reviewer?(current_user)
          Application.where("proofs @> ?::jsonb", [{ id: id }].to_json).first
        elsif current_user
          Application.where(user_id: current_user.id).where("proofs @> ?::jsonb", [{ id: id }].to_json).first
        else
          Registration.current_application(session)
        end
      raise Discourse::NotFound unless application
      path = Proofs.download(application, id)
      send_file path, type: "image/jpeg", disposition: "inline", filename: "alumni-proof-#{id}.jpg"
    end

    def resend
      Registration.resend!(Registration.current_application(session))
      render json: success_json
    end

    private

    def ensure_registration
      Registration.ensure_enabled!
    end

    def ensure_new_account
      raise Discourse::InvalidAccess if current_user
    end

    def set_private_headers
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["Vary"] = "Cookie"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
    end

    def owner_status(application)
      { verified: true, email: application.email, status: application.status, application: application.public_status }
    end
  end
end
