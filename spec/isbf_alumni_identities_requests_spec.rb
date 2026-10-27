# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ISBF Alumni identities", type: :request do
  fab!(:alumni_group) { Fabricate(:group, name: "alumni") }
  fab!(:viewer) { Fabricate(:user, active: true, approved: true) }
  fab!(:member) { Fabricate(:user, active: true, approved: true) }

  before do
    SiteSetting.isbf_alumni_enabled = true
    SiteSetting.isbf_alumni_group_name = alumni_group.name
    SiteSetting.login_required = false
    alumni_group.add(member)
  end

  def identities(ids)
    get "/isbf/alumni/identities.json", params: { user_ids: ids }
  end

  def expect_memberships(expected)
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body).to eq("memberships" => expected)
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
  end

  it "allows guests to read only requested identities regardless of directory visibility" do
    member.upsert_custom_fields(IsbfAlumni::VISIBLE_FIELD => "false")
    identities([member.id, viewer.id])
    expect_memberships(member.id.to_s => true, viewer.id.to_s => false)
    expect(response.body).not_to include(member.username, member.email, "proof", "application", "display_name")
  end

  it "allows ordinary nonmember viewers" do
    sign_in(viewer)
    identities([member.id, viewer.id])
    expect_memberships(member.id.to_s => true, viewer.id.to_s => false)
  end

  it "rate limits signed in viewers by their native user identity" do
    sign_in(viewer)
    allow(RateLimiter).to receive(:new).and_call_original
    expect(RateLimiter).to receive(:new).with(viewer, "isbf-alumni-identities", 120, 1.minute).and_call_original
    identities([member.id])
    expect_memberships(member.id.to_s => true)
  end

  it "rate limits anonymous requests by IP without putting the raw address in the key" do
    identities([member.id])
    key = "isbf-alumni-identities-ip-#{Digest::SHA256.hexdigest(request.remote_ip)}"
    allow(RateLimiter).to receive(:new).and_call_original
    expect(RateLimiter).to receive(:new).with(nil, key, 60, 1.minute).and_call_original
    identities([member.id])
    expect_memberships(member.id.to_s => true)
  end

  it "does not treat a pending application as membership" do
    IsbfAlumni::Application.create!(email: viewer.email, user: viewer, status: "pending", email_verified_at: Time.current)
    identities([viewer.id])
    expect_memberships(viewer.id.to_s => false)
  end

  it "uses only the configured group's exact membership" do
    custom_group = Fabricate(:group)
    custom_group.add(viewer)
    SiteSetting.isbf_alumni_group_name = custom_group.name
    identities([member.id, viewer.id])
    expect_memberships(member.id.to_s => false, viewer.id.to_s => true)
  end

  it "deduplicates canonical IDs" do
    identities([member.id, member.id, viewer.id])
    expect_memberships(member.id.to_s => true, viewer.id.to_s => false)
  end

  it "reflects removed membership on the next request" do
    identities([member.id])
    expect_memberships(member.id.to_s => true)
    alumni_group.remove(member)
    identities([member.id])
    expect_memberships(member.id.to_s => false)
  end

  it "returns false for nonexistent, inactive, and unapproved users" do
    inactive = Fabricate(:user, active: false, approved: true)
    unapproved = Fabricate(:user, active: true, approved: false)
    alumni_group.add(inactive)
    alumni_group.add(unapproved)
    missing_id = User.maximum(:id) + 1
    identities([inactive.id, unapproved.id, missing_id])
    expect_memberships(inactive.id.to_s => false, unapproved.id.to_s => false, missing_id.to_s => false)
  end

  it "accepts up to 100 IDs without querying each user separately" do
    missing_id = User.maximum(:id) + 1
    ids = [member.id, viewer.id] + (missing_id...(missing_id + 98)).to_a
    identities([member.id])
    baseline = track_sql_queries { identities([member.id]) }
    batched = track_sql_queries { identities(ids) }
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.fetch("memberships").size).to eq(100)
    expect(batched.size).to be <= baseline.size
  end

  [nil, [], "1", { "id" => "1" }, ["0"], ["-1"], ["01"], ["+1"], ["1.0"], ["1e2"], [" 1"], ["alumni"], ["2147483648"], ["9" * 100], [{ "id" => "1" }], ["1"] * 101].each do |invalid|
    it "rejects malformed or oversized ID input #{invalid.inspect.truncate(80)}" do
      identities(invalid)
      expect(response.status).to eq(422), response.body
      expect(response.parsed_body).not_to have_key("memberships")
    end
  end

  it "rejects nested ID arrays when the request encoding preserves their shape" do
    get "/isbf/alumni/identities.json", params: { user_ids: [["1"]] }, as: :json
    expect(response.status).to eq(422), response.body
    expect(response.parsed_body).not_to have_key("memberships")
  end

  it "rejects system account IDs" do
    identities([Discourse.system_user.id])
    expect(response.status).to eq(422), response.body
  end

  it "does not infer an identity from a username" do
    get "/isbf/alumni/identities.json", params: { username: member.username }
    expect(response.status).to eq(422), response.body
  end

  it "retains the site's native login requirement" do
    SiteSetting.login_required = true
    identities([member.id])
    expect(response.status).to eq(403), response.body
    expect(response.parsed_body).not_to have_key("memberships")
  end

  it "requires JSON or XHR through the native controller check" do
    get "/isbf/alumni/identities", params: { user_ids: [member.id] }
    expect(response.body).not_to include('"memberships"')
  end

  it "does not expose membership when the plugin is disabled" do
    SiteSetting.isbf_alumni_enabled = false
    identities([member.id])
    expect(response.status).to eq(404), response.body
    expect(response.parsed_body).not_to have_key("memberships")
  end

  it "does not expose membership when the configured group is absent" do
    SiteSetting.isbf_alumni_group_name = "missing_alumni_group"
    identities([member.id])
    expect(response.status).to eq(403), response.body
    expect(response.parsed_body).not_to have_key("memberships")
  end
end
