# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ISBF Alumni invitation metadata", type: :request do
  fab!(:alumni_group) { Fabricate(:group, name: "alumni") }
  fab!(:official_group, :group)
  fab!(:official_category, :category)
  fab!(:inviter, :admin)
  let!(:application) do
    IsbfAlumni::Application.create!(
      email: "metadata-invite@example.com", email_verified_at: Time.current, status: "approved",
      real_name: "Private Legal Identity", proofs: [{ "id" => SecureRandom.uuid, "bytes" => 123 }],
    )
  end
  let(:invite) do
    record = Invite.new(
      invited_by: inviter, email: application.email, max_redemptions_allowed: 1,
      expires_at: 7.days.from_now, emailed_status: Invite.emailed_status_types[:not_required],
    )
    record.isbf_alumni_application_id = application.id
    record.save!
    application.update!(invite: record)
    record
  end
  before do
    SiteSetting.isbf_alumni_enabled = true
    SiteSetting.isbf_alumni_group_name = alumni_group.name
    SiteSetting.isbf_alumni_registration_enabled = true
    SiteSetting.academy_official_group = official_group.id
    SiteSetting.academy_official_category = official_category.id
    SiteSetting.academy_roles_enabled = true
    SiteSetting.academy_auth_page_enabled = true
    SiteSetting.allow_new_registrations = true
    SiteSetting.enable_local_logins = true
  end

  def invite_info(format)
    get "/invites/#{invite.invite_key}", headers: format == :json ? { "ACCEPT" => "application/json" } : {}
    expect(response.status).to eq(200), response.body
    return response.parsed_body if format == :json

    preloaded = Nokogiri::HTML(response.body).at_css("script#data-preloaded")
    JSON.parse(JSON.parse(preloaded.text).fetch("invite_info"))
  end

  %i[json html].each do |format|
    it "adds only a boolean to the native #{format} invite information" do
      info = invite_info(format)
      expect(info.fetch("isbf_alumni_invite")).to eq(true)
      expect(info).to include("invited_by", "email", "hidden_email", "username", "is_invite_link")
      expect(info.keys.grep(/application|proof|real_name|graduation/)).to be_empty
      expect(response.body).not_to include(application.real_name, application.proofs.first.fetch("id"))
    end

    it "preserves ordinary invitations in #{format}" do
      invite
      application.destroy!
      DiscourseAcademyRoles::StudentRegistration.create!(invite: invite, issued_by: inviter, student_number: "metadata-student-fixture")
      expect(invite_info(format).fetch("isbf_alumni_invite")).to eq(false)
    end

    it "keeps approved invitations usable when new applications close in #{format}" do
      invite
      SiteSetting.isbf_alumni_registration_enabled = false
      expect(invite_info(format).fetch("isbf_alumni_invite")).to eq(true)
    end

    it "does not mark invites while the Alumni plugin is disabled in #{format}" do
      invite
      SiteSetting.isbf_alumni_enabled = false
      SiteSetting.academy_roles_enabled = false
      expect(invite_info(format).fetch("isbf_alumni_invite")).to eq(false)
    end

    it "does not mark stale application bindings in #{format}" do
      invite
      application.update!(status: "rejected")
      get "/invites/#{invite.invite_key}", headers: format == :json ? { "ACCEPT" => "application/json" } : {}
      if format == :json
        expect(response.status).to eq(404), response.body
        expect(response.parsed_body["isbf_alumni_invite"]).not_to eq(true)
      else
        expect(Nokogiri::HTML(response.body).at_css("script#data-preloaded")).to be_nil
      end
    end

    it "does not mark an existing authenticated invitee in #{format}" do
      sign_in(Fabricate(:user))
      expect(invite_info(format).fetch("isbf_alumni_invite")).to eq(false)
    end

    it "does not mark an email already owned by a normal account in #{format}" do
      Fabricate(:user, email: invite.email)
      expect(invite_info(format).fetch("isbf_alumni_invite")).to eq(false)
    end

    it "does not expose Alumni metadata from an expired invite in #{format}" do
      invite.update!(expires_at: 1.day.ago)
      get "/invites/#{invite.invite_key}", headers: format == :json ? { "ACCEPT" => "application/json" } : {}
      expect(response.body).not_to include('"isbf_alumni_invite":true', application.real_name, application.proofs.first.fetch("id"))
    end
  end

  [true, false].each do |with_password|
    it "redeems a real native email-code invitation and logs in #{with_password ? 'with a password' : 'without a password'}" do
      SiteSetting.enable_local_logins_via_email = true
      SiteSetting.enable_local_logins_via_code = true
      SiteSetting.must_approve_users = false
      SiteSetting.invite_only = false
      code = EmailLoginCode.generate!(email: invite.email).code
      expect do
        post "/session/login-code/verify.json", params: { invite_key: invite.invite_key, code: code }
      end.not_to change(User, :count)
      expect(response.parsed_body["username_required"]).to eq(true)
      post "/session/login-code/verify.json",
           params: { invite_key: invite.invite_key, code: code, username: "alumni_fixture" }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body["account_created"]).to eq(true), response.body
      created = application.reload.user
      expect(application.status).to eq("registered")
      expect(created.has_password?).to eq(false)
      expect(created.groups).to include(alumni_group)
      expect(invite.reload).to be_redeemed
      password = "native-fixture-#{SecureRandom.hex(16)}"
      if with_password
        put "/isbf/alumni/initial-password.json", params: { password: password, invite_key: invite.invite_key }
        expect(response.status).to eq(200), response.body
        expect(created.reload.confirm_password?(password)).to eq(true)
      end
      get "/session/current.json"
      expect(response.parsed_body.dig("current_user", "id")).to eq(created.id)
      browser = ActionDispatch::Integration::Session.new(Rails.application)
      browser.host! request.host
      browser.https! request.ssl?
      if with_password
        browser.post "/session.json", params: { login: created.username, password: password }
      else
        login_code = EmailLoginCode.generate!(email: created.email).code
        browser.post "/session/login-code/verify.json", params: { email: created.email, code: login_code }
      end
      expect(browser.response.status).to eq(200), browser.response.body
      browser.get "/session/current.json"
      expect(browser.response.status).to eq(200), browser.response.body
      expect(browser.response.parsed_body.dig("current_user", "id")).to eq(created.id)
      expect(User.real.where(staged: false).with_email(invite.email).count).to eq(1)
    end
  end
end

RSpec.describe IsbfAlumni::InvitationMetadata do
  it "clears the scoped context even when native invite rendering raises" do
    native = Class.new do
      private

      def show_invite(invite)
        raise "native rendering failed"
      end
    end
    native.prepend(described_class)
    controller = native.new
    expect { controller.send(:show_invite, Object.new) }.to raise_error("native rendering failed")
    expect(controller.instance_variable_defined?(:@isbf_alumni_invite_context)).to eq(false)
  end
end
