# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfAlumni::Registration do
  fab!(:alumni_group) { Fabricate(:group, name: "alumni") }
  fab!(:official_group, :group)
  fab!(:official_category, :category)
  fab!(:developer, :admin)
  fab!(:administrator, :moderator)
  let(:email) { "newalumni@example.com" }
  let(:owner_session) { {} }

  before do
    unless defined?(DiscourseAcademyRoles::StudentInviteExtension)
      raise "Alumni registration integration tests require the real academy identity plugin"
    end
    SiteSetting.isbf_alumni_enabled = true
    SiteSetting.isbf_alumni_group_name = alumni_group.name
    SiteSetting.isbf_alumni_registration_enabled = true
    SiteSetting.academy_official_group = official_group.id
    SiteSetting.academy_official_category = official_category.id
    SiteSetting.academy_roles_enabled = true
    SiteSetting.disable_emails = "no"
    @private_fixture_paths = []
  end

  after do
    @private_fixture_paths.each { |path| File.delete(path) if File.file?(path) }
  end

  def verified_application(address = email)
    described_class.request_code(email: address, session: owner_session, ip: "192.0.2.10")
    challenge = described_class.challenge(owner_session.fetch(:isbf_alumni_challenge))
    code = described_class.verification_code(challenge)
    described_class.verify_code(code: code, session: owner_session)
  end

  # These fixtures exercise application ownership, not the image conversion pipeline.
  def attach_private_proof(application)
    id = SecureRandom.uuid
    path = IsbfAlumni::Proofs.path(id)
    File.binwrite(path, "authorization-test-fixture")
    @private_fixture_paths << path
    application.update!(proofs: [{ "id" => id, "bytes" => File.size(path) }])
    id
  end

  def submit_application(application, **attributes)
    proof = attach_private_proof(application)
    described_class.submit!(application, {
      real_name: "Private Legal Name",
      graduation_year: 2020,
      proof_ids: [proof],
    }.merge(attributes))
  end

  def approved_application(**attributes)
    application = submit_application(verified_application, **attributes)
    described_class.approve!(application, developer)
    application.reload
  end

  it "verifies an email without creating an account and consumes the code exactly once" do
    expect { verified_application }.not_to change(User, :count)
    application = described_class.current_application(owner_session)
    expect(application.email_verified_at).to be_present
    expect(application.email).to eq(email)
    expect { described_class.verify_code(code: "123456", session: owner_session) }.to raise_error(
      IsbfAlumni::RegistrationError,
    )
  end

  it "rejects wrong codes without granting an owner session" do
    described_class.request_code(email: email, session: owner_session, ip: "192.0.2.10")
    challenge = described_class.challenge(owner_session.fetch(:isbf_alumni_challenge))
    correct = described_class.verification_code(challenge)
    wrong = correct == "000000" ? "000001" : "000000"
    expect { described_class.verify_code(code: wrong, session: owner_session) }.to raise_error(
      IsbfAlumni::RegistrationError,
    )
    expect { described_class.current_application(owner_session) }.to raise_error(Discourse::InvalidAccess)
    expect(IsbfAlumni::Application.where(email: email)).to be_empty
  end

  it "normalizes email identity and reuses the same application after re-verification" do
    first = verified_application("  NewAlumni@example.com ")
    second = verified_application(email)
    expect(second.id).to eq(first.id)
    expect(IsbfAlumni::Application.where(email: email).count).to eq(1)
    duplicate = IsbfAlumni::Application.new(email: email, email_verified_at: Time.current)
    expect(duplicate).not_to be_valid
  end

  it "does not verify an existing community account or expose its existence in the request response" do
    Fabricate(:user, email: email)
    expect(described_class.request_code(email: email, session: owner_session, ip: "192.0.2.10")).to eq(true)
    challenge = described_class.challenge(owner_session.fetch(:isbf_alumni_challenge))
    expect {
      described_class.verify_code(code: described_class.verification_code(challenge), session: owner_session)
    }.to raise_error(IsbfAlumni::RegistrationError)
    expect(IsbfAlumni::Application.where(email: email)).to be_empty
  end

  it "requires a real name, valid graduation year and owned proofs while leaving profile fields optional" do
    application = verified_application
    proof = attach_private_proof(application)
    valid = { real_name: "Graduate", graduation_year: 2020, proof_ids: [proof] }
    expect { described_class.submit!(application, valid.merge(real_name: "  ")) }.to raise_error(Discourse::InvalidParameters)
    expect { described_class.submit!(application, valid.merge(graduation_year: Time.zone.today.year + 1)) }.to raise_error(IsbfAlumni::RegistrationError)
    expect { described_class.submit!(application, valid.merge(proof_ids: [])) }.to raise_error(IsbfAlumni::RegistrationError)
    expect { described_class.submit!(application, valid.merge(proof_ids: [SecureRandom.uuid])) }.to raise_error(IsbfAlumni::RegistrationError)
    described_class.submit!(application, valid)
    expect(application.reload.status).to eq("pending")
    expect(application.profile.fetch("visible")).to eq(false)
    expect(application.profile.fetch("bio")).to eq("")
  end

  it "requires a rejection reason and reuses the existing reviewable when a rejected applicant resubmits" do
    application = submit_application(verified_application)
    reviewable = application.reviewable
    expect { described_class.reject!(application, developer, " ") }.to raise_error(Discourse::InvalidParameters)
    expect(reviewable.perform(developer, :reject_alumni, reject_reason: "Please provide clearer evidence").success?).to eq(true)
    expect(application.reload.status).to eq("rejected")
    expect {
      described_class.submit!(application, real_name: "Graduate", graduation_year: 2020, proof_ids: application.submitted_proof_ids)
    }.not_to change(ReviewableIsbfAlumni, :count)
    expect(application.reload.reviewable_id).to eq(reviewable.id)
    expect(reviewable.reload).to be_pending
    expect(application.submissions.length).to eq(2)
  end

  it "creates one email-bound seven-day invite and does not recreate it during mail retry" do
    freeze_time
    application = approved_application
    invite = application.invite
    expect(invite.email).to eq(email)
    expect(invite.expires_at).to be_within(1.second).of(7.days.from_now)
    expect(invite.max_redemptions_allowed).to eq(1)
    expect(invite).not_to be_admin
    expect(invite).not_to be_moderator
    expect(described_class.bound_invite?(invite)).to eq(true)
    expect(application.mail_version).to eq(1)
    application.update!(mail_status: "failed")
    expect { described_class.resend!(application) }.not_to change(Invite, :count)
    expect(application.reload.invite_id).to eq(invite.id)
    expect(application.mail_version).to eq(2)
    expect { described_class.approve!(application, developer) }.to raise_error(IsbfAlumni::RegistrationError)
  end

  it "ignores stale decision jobs and sends the current mail version only once" do
    application = approved_application
    sender = instance_double(Email::Sender, send: true)
    allow(Email::Sender).to receive(:new).and_return(sender)
    job = Jobs::IsbfAlumniDecisionEmail.new
    job.execute(application_id: application.id, version: application.mail_version - 1)
    expect(sender).not_to have_received(:send)
    2.times { job.execute(application_id: application.id, version: application.mail_version) }
    expect(sender).to have_received(:send).once
    expect(application.reload.mail_status).to eq("sent")
  end

  it "reissues an expired registration link and invalidates the original link" do
    application = approved_application
    old_invite = application.invite
    old_invite.update!(expires_at: 1.day.ago)
    described_class.resend!(application)
    expect(application.reload.invite_id).not_to eq(old_invite.id)
    expect(old_invite.reload.invalidated_at).to be_present
    expect(old_invite).not_to be_redeemable
    expect(application.invite).to be_redeemable
  end

  it "binds a genuinely redeemed native invitation to the alumni group and public profile without publishing legal identity" do
    application = approved_application(country_code: "CN", region_code: "GD", industry: "Finance", bio: "Hello alumni")
    user = InviteRedeemer.new(invite: application.invite, email: email, password: "verystrongpassword").redeem
    expect(alumni_group.users).to include(user)
    expect(application.reload.user).to eq(user)
    expect(application.status).to eq("registered")
    expect(application.registered_at).to be_present
    expect(user.name).not_to eq(application.real_name)
    expect(user.custom_fields[IsbfAlumni::BIO_FIELD]).to eq("Hello alumni")
    expect(user.custom_fields[IsbfAlumni::VISIBLE_FIELD]).to eq("false")
    expect(user.custom_fields.values).not_to include(application.real_name)
    expect(described_class.bound_invite?(application.invite)).to eq(false)
    expect(application.invite.reload.redemption_count).to eq(1)
  end

  it "rejects a wrong-email redemption and an existing logged-in identity without creating or binding accounts" do
    application = approved_application
    expect {
      InviteRedeemer.new(invite: application.invite, email: "other@example.com", password: "verystrongpassword").redeem
    }.to raise_error(Discourse::InvalidAccess)
    existing = Fabricate(:user)
    expect {
      described_class.redeem(invite: application.invite, email: email, redeeming_user: existing) { existing }
    }.to raise_error(Discourse::InvalidAccess)
    expect(application.reload.user_id).to be_nil
    expect(application.invite.reload.redemption_count).to eq(0)
  end

  it "rejects an account created after verification before yielding to native account creation" do
    application = approved_application
    Fabricate(:user, email: email)
    expect {
      described_class.redeem(invite: application.invite, email: email, redeeming_user: nil) { raise "must not create an account" }
    }.to raise_error(Invite::UserExists)
  end

  it "does not turn unrelated, privileged or domain invitations into alumni registration links" do
    application = approved_application
    invite = application.invite
    [[:email, "other@example.com"], [:domain, "example.com"], [:max_redemptions_allowed, 2], [:admin, true], [:moderator, true]].each do |attribute, value|
      original = invite.public_send(attribute)
      invite.public_send("#{attribute}=", value)
      expect(described_class.bound_invite?(invite)).to eq(false)
      invite.public_send("#{attribute}=", original)
    end
    application.update!(status: "rejected")
    expect(described_class.bound_invite?(invite)).to eq(false)
  end

  it "authorizes a delegated reviewer independently of email and user-edit privileges and revokes immediately" do
    application = submit_application(verified_application)
    expect { described_class.approve!(application, administrator) }.to raise_error(Discourse::InvalidAccess)
    SiteSetting.academy_moderators_review_alumni = true
    expect(Reviewable.viewable_by(administrator)).to include(application.reviewable)
    expect(administrator.guardian.can_see_emails?).to eq(false)
    expect(administrator.guardian.academy_can?(:edit_users)).to eq(false)
    expect(application.reviewable.actions_for(administrator.guardian).has?(:approve_alumni)).to eq(true)
    SiteSetting.academy_moderators_review_alumni = false
    expect(Reviewable.viewable_by(administrator)).not_to include(application.reviewable)
    expect { application.reviewable.perform(administrator, :approve_alumni) }.to raise_error(Discourse::InvalidAccess)
  end
end
