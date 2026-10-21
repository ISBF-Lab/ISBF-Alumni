# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ISBF Alumni registration and private evidence", type: :request do
  fab!(:alumni_group) { Fabricate(:group, name: "alumni") }
  fab!(:official_group, :group)
  fab!(:official_category, :category)
  fab!(:developer, :admin)
  fab!(:administrator, :moderator)
  fab!(:member, :user)

  before do
    unless defined?(DiscourseAcademyRoles::StudentInviteExtension)
      raise "Alumni registration request tests require the real academy identity plugin"
    end
    SiteSetting.isbf_alumni_enabled = true
    SiteSetting.isbf_alumni_group_name = alumni_group.name
    SiteSetting.isbf_alumni_registration_enabled = true
    SiteSetting.academy_official_group = official_group.id
    SiteSetting.academy_official_category = official_category.id
    SiteSetting.academy_roles_enabled = true
    @private_fixture_paths = []
    @latest_challenge = nil
    allow(Jobs).to receive(:enqueue).and_wrap_original do |original, name, **args|
      @latest_challenge = args[:challenge_id] if name == :isbf_alumni_verification_email
      original.call(name, **args)
    end
  end

  after do
    @private_fixture_paths.each { |path| File.delete(path) if File.file?(path) }
  end

  def verify_browser_email(email = "requestalumni@example.com")
    post "/isbf/alumni/applications/email.json", params: { email: email }
    expect(response.status).to eq(200), response.body
    challenge = IsbfAlumni::Registration.challenge(@latest_challenge)
    code = IsbfAlumni::Registration.verification_code(challenge)
    expect(response.body).not_to include(code)
    post "/isbf/alumni/applications/verify-email.json", params: { code: code }
    expect(response.status).to eq(200), response.body
    IsbfAlumni::Application.find(response.parsed_body.fetch("application").fetch("id"))
  end

  # Evidence content here is an authorization fixture, not an image-conversion assertion.
  def attach_private_proof(application)
    id = SecureRandom.uuid
    path = IsbfAlumni::Proofs.path(id)
    File.binwrite(path, "private-evidence-authorization-fixture")
    @private_fixture_paths << path
    application.update!(proofs: [{ "id" => id, "bytes" => File.size(path) }])
    id
  end

  def private_application
    application = IsbfAlumni::Application.create!(email: "proofowner@example.com", email_verified_at: Time.current)
    id = attach_private_proof(application)
    [application, id]
  end

  it "requires verified email ownership before submission and never creates a user during verification" do
    post "/isbf/alumni/applications.json", params: { real_name: "Graduate", graduation_year: 2020, proof_ids: [] }
    expect(response.status).to eq(403)
    expect { verify_browser_email }.not_to change(User, :count)
    get "/isbf/alumni/applications/current.json"
    expect(response.parsed_body.fetch("verified")).to eq(true)
    expect(response.headers.fetch("Cache-Control")).to include("no-store")
  end

  it "rejects a replayed email code and keeps a different browser outside the verified application" do
    application = verify_browser_email
    challenge_id = @latest_challenge
    expect(IsbfAlumni::Registration.challenge(challenge_id)).to be_nil
    post "/isbf/alumni/applications/verify-email.json", params: { code: "123456" }
    expect(response.status).to eq(422)
    other_browser = ActionDispatch::Integration::Session.new(Rails.application)
    other_browser.get "/isbf/alumni/applications/current.json"
    expect(other_browser.response.parsed_body).to eq("verified" => false)
    expect(IsbfAlumni::Application.count).to eq(1)
    expect(application.reload.user_id).to be_nil
  end

  it "rejects logged-in signup attempts and does not turn the form into a second-account path" do
    sign_in(member)
    post "/isbf/alumni/applications/email.json", params: { email: "another@example.com" }
    expect(response.status).to eq(403)
    post "/isbf/alumni/applications.json", params: { real_name: "Graduate", graduation_year: 2020 }
    expect(response.status).to eq(403)
    expect(IsbfAlumni::Application.count).to eq(0)
  end

  it "validates fields without losing ownership or previously uploaded evidence" do
    application = verify_browser_email
    id = attach_private_proof(application)
    post "/isbf/alumni/applications.json", params: { real_name: " ", graduation_year: 2020, proof_ids: [id] }
    expect(response.status).to eq(422), response.body
    expect(application.reload.status).to eq("draft")
    expect(File.file?(IsbfAlumni::Proofs.path(id))).to eq(true)
    post "/isbf/alumni/applications.json", params: { real_name: "Graduate", graduation_year: 2020, proof_ids: [id] }
    expect(response.status).to eq(200), response.body
    expect(application.reload.status).to eq("pending")
    expect(application.reviewable).to be_a(ReviewableIsbfAlumni)
    expect {
      post "/isbf/alumni/applications.json", params: { real_name: "Graduate", graduation_year: 2020, proof_ids: [id] }
    }.not_to change(ReviewableIsbfAlumni, :count)
  end

  it "allows a verified browser to read its own private proof and rejects another direct proof ID" do
    application = verify_browser_email
    own_id = attach_private_proof(application)
    _other_application, other_id = private_application
    get "/isbf/alumni/application-proofs/#{own_id}"
    expect(response.status).to eq(200), response.body
    expect(response.media_type).to eq("image/jpeg")
    expect(response.headers.fetch("Cache-Control")).to include("no-store")
    expect(response.headers.fetch("X-Content-Type-Options")).to eq("nosniff")
    get "/isbf/alumni/application-proofs/#{other_id}"
    expect(response.status).to eq(404)
    other_browser = ActionDispatch::Integration::Session.new(Rails.application)
    other_browser.get "/isbf/alumni/application-proofs/#{own_id}"
    expect(other_browser.response.status).to eq(403)
  end

  it "prevents an ordinary member from reading another applicant's proof" do
    _application, id = private_application
    sign_in(member)
    get "/isbf/alumni/application-proofs/#{id}"
    expect(response.status).to eq(404)
  end

  it "allows a registered applicant to retain access only to their own evidence" do
    application, id = private_application
    application.update!(status: "registered", user: member, registered_at: Time.current)
    sign_in(member)
    get "/isbf/alumni/application-proofs/#{id}"
    expect(response.status).to eq(200)
  end

  it "guards direct evidence URLs with the delegated alumni-review switch and revokes access immediately" do
    _application, id = private_application
    sign_in(administrator)
    get "/isbf/alumni/application-proofs/#{id}"
    expect(response.status).to eq(404)
    SiteSetting.academy_moderators_review_alumni = true
    get "/isbf/alumni/application-proofs/#{id}"
    expect(response.status).to eq(200), response.body
    expect(administrator.guardian.can_see_emails?).to eq(false)
    SiteSetting.academy_moderators_review_alumni = false
    get "/isbf/alumni/application-proofs/#{id}"
    expect(response.status).to eq(404)
  end

  it "permits developer evidence review while management writes are closed" do
    _application, id = private_application
    SiteSetting.isbf_alumni_registration_enabled = false
    sign_in(developer)
    get "/isbf/alumni/application-proofs/#{id}"
    expect(response.status).to eq(200), response.body
    get "/isbf/alumni/application-proofs/not-a-uuid"
    expect(response.status).to be_in([403, 404])
  end

  it "does not expose legal identity, email or proof links in the public alumni directory" do
    application, id = private_application
    application.update!(status: "registered", user: member, real_name: "Never Public Legal Name", graduation_year: 2020)
    alumni_group.add(member)
    member.upsert_custom_fields(IsbfAlumni::VISIBLE_FIELD => "true", IsbfAlumni::DISPLAY_NAME_FIELD => "Public Name", IsbfAlumni::COUNTRY_FIELD => "CN", IsbfAlumni::REGION_FIELD => "GD")
    sign_in(member)
    get "/isbf/alumni/directory.json", params: { country: "CN", region: "GD" }
    expect(response.status).to eq(200)
    expect(response.body).not_to include(application.email, application.real_name, id)
  end
end
