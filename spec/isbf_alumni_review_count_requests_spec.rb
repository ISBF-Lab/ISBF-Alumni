# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ISBF Alumni native review count compatibility", type: :request do
  fab!(:alumni_group) { Fabricate(:group, name: "alumni") }
  fab!(:official_group, :group)
  fab!(:official_category, :category)
  fab!(:developer, :admin)
  fab!(:administrator, :moderator)
  fab!(:member, :user)

  before do
    unless defined?(DiscourseAcademyRoles::StudentInviteExtension)
      raise "Review count request tests require the real academy identity plugin"
    end

    SiteSetting.isbf_alumni_enabled = true
    SiteSetting.isbf_alumni_group_name = alumni_group.name
    SiteSetting.isbf_alumni_registration_enabled = true
    SiteSetting.academy_official_group = official_group.id
    SiteSetting.academy_official_category = official_category.id
    SiteSetting.academy_roles_enabled = true
    SiteSetting.academy_moderators_review_content = false
    SiteSetting.academy_moderators_review_alumni = false
  end

  def create_alumni_reviewable
    application =
      IsbfAlumni::Application.create!(
        email: "private-count-applicant@example.com",
        email_verified_at: Time.current,
        real_name: "Private Count Applicant",
        graduation_year: 2020,
        status: "pending",
      )
    reviewable =
      ReviewableIsbfAlumni.needs_review!(
        created_by: Discourse.system_user,
        reviewable_by_moderator: true,
        potential_spam: false,
        payload: { "application_id" => application.id },
      )
    reviewable.update!(force_review: true)
    application.update!(reviewable: reviewable)
    reviewable
  end

  def expect_review_count(count)
    get "/review/count.json"
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body).to eq("count" => count)
  end

  it "returns native keyword-only counts before and after a real review action" do
    sign_in(developer)
    expect_review_count(0)

    reviewable = create_alumni_reviewable
    expect_review_count(1)
    get "/review.json"
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.fetch("meta").fetch("total_rows_reviewables")).to eq(1)
    expect(response.parsed_body.fetch("meta").fetch("reviewable_types")).to include(
      "ReviewableIsbfAlumni",
    )
    expect(response.parsed_body.fetch("__rest_serializer")).to eq("1")

    put "/review/#{reviewable.id}/perform/reject_alumni.json",
        params: { version: reviewable.reload.version, reject_reason: "Please replace this evidence" }
    expect(response.status).to eq(200), response.body
    expect(reviewable.reload).to be_rejected
    expect_review_count(0)
  end

  it "counts only alumni for a delegated alumni reviewer without general review permission" do
    create_alumni_reviewable
    Fabricate(:reviewable_flagged_post, force_review: true)
    SiteSetting.academy_moderators_review_alumni = true
    sign_in(administrator)

    expect_review_count(1)
    get "/review.json"
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.fetch("meta").fetch("total_rows_reviewables")).to eq(1)
    expect(response.parsed_body.fetch("reviewables").map { |item| item.fetch("type") }).to eq(
      ["ReviewableIsbfAlumni"],
    )
    expect(administrator.guardian.can_see_emails?).to eq(false)
  end

  it "updates counts and removes private metadata when the alumni permission is revoked" do
    alumni = create_alumni_reviewable
    Fabricate(:reviewable_flagged_post, force_review: true)
    SiteSetting.academy_moderators_review_content = true
    SiteSetting.academy_moderators_review_alumni = true
    sign_in(administrator)
    expect_review_count(2)

    SiteSetting.academy_moderators_review_alumni = false
    expect_review_count(1)
    get "/review.json"
    expect(response.status).to eq(200), response.body
    metadata = response.parsed_body.fetch("meta")
    expect(metadata.fetch("total_rows_reviewables")).to eq(1)
    expect(metadata.fetch("reviewable_types")).not_to include("ReviewableIsbfAlumni")
    expect(response.parsed_body.fetch("__rest_serializer")).to eq("1")
    expect(response.body).not_to include(alumni.application.email, alumni.application.real_name)
  end

  it "preserves native count rendering while the alumni feature is disabled" do
    SiteSetting.isbf_alumni_enabled = false
    sign_in(developer)
    expect_review_count(0)
  end

  it "does not expose the review count to an ordinary member" do
    create_alumni_reviewable
    sign_in(member)
    get "/review/count.json"
    expect(response.status).to eq(403), response.body
    expect(response.parsed_body).not_to have_key("count")
  end

  it "requires a logged-in session for the count endpoint" do
    get "/review/count.json"
    expect(response.status).to eq(403), response.body
    expect(response.parsed_body).not_to have_key("count")
  end
end
