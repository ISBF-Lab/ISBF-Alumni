# frozen_string_literal: true

module IsbfAlumni
  class IdentitiesController < ::ApplicationController
    MAX_USER_IDS = 100
    MAX_USER_ID = 2_147_483_647

    wrap_parameters false
    requires_plugin "isbf-alumni"
    before_action :set_private_headers
    before_action :ensure_available!

    def index
      limiter_key =
        if current_user
          "isbf-alumni-identities"
        else
          "isbf-alumni-identities-ip-#{Digest::SHA256.hexdigest(request.remote_ip)}"
        end
      RateLimiter.new(current_user, limiter_key, current_user ? 120 : 60, 1.minute).performed!
      user_ids = requested_user_ids
      eligible_users = User.where(id: user_ids, active: true, approved: true)
      member_ids = GroupUser.where(group_id: @alumni_group.id, user_id: eligible_users.select(:id)).pluck(:user_id)
      memberships = user_ids.to_h { |id| [id.to_s, false] }
      member_ids.each { |id| memberships[id.to_s] = true }
      render json: { memberships: memberships }
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
    end

    private

    def requested_user_ids
      values = params[:user_ids]
      unless values.is_a?(Array) && values.length.between?(1, MAX_USER_IDS)
        raise Discourse::InvalidParameters.new("user_ids")
      end

      values.map do |value|
        unless value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,9}\z/) && value.to_i <= MAX_USER_ID
          raise Discourse::InvalidParameters.new("user_ids")
        end
        value.to_i
      end.uniq
    end

    def ensure_available!
      raise Discourse::InvalidAccess unless IsbfAlumni.enabled? && (@alumni_group = IsbfAlumni.group)
    end

    def set_private_headers
      response.headers["Cache-Control"] = "private, no-store"
    end
  end
end
