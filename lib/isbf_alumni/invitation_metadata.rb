# frozen_string_literal: true

module IsbfAlumni
  module InvitationMetadata
    private

    def show_invite(invite)
      @isbf_alumni_invite_context = invite
      super
    ensure
      remove_instance_variable(:@isbf_alumni_invite_context) if defined?(@isbf_alumni_invite_context)
    end

    def render_json_dump(obj, opts = nil)
      if @isbf_alumni_invite_context && obj.is_a?(Hash) && obj.key?(:invited_by)
        obj = obj.merge(isbf_alumni_invite: isbf_alumni_invite?)
      end
      super(obj, opts)
    end

    def store_preloaded(key, json)
      if @isbf_alumni_invite_context && key == "invite_info"
        json = MultiJson.dump(MultiJson.load(json).merge("isbf_alumni_invite" => isbf_alumni_invite?))
      end
      super(key, json)
    end

    def isbf_alumni_invite?
      invite = @isbf_alumni_invite_context
      !!(current_user.nil? && IsbfAlumni.available? && Registration.bound_invite?(invite) &&
        invite.redeemable? && User.real.where(staged: false).find_by_email(invite.email).nil?)
    end
  end
end
