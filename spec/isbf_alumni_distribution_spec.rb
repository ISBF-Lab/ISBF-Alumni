# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ISBF Alumni distribution", type: :request do
  fab!(:alumni_group) { Fabricate(:group, name: "alumni") }
  fab!(:viewer) { Fabricate(:user, active: true, approved: true) }

  before do
    SiteSetting.isbf_alumni_enabled = true
    SiteSetting.isbf_alumni_group_name = "alumni"
  end

  def alumni(country: "CN", region: "GD", city: "4403", visible: true, active: true, approved: true)
    user = Fabricate(:user, active: active, approved: approved)
    alumni_group.add(user)
    user.upsert_custom_fields(
      IsbfAlumni::COUNTRY_FIELD => country,
      IsbfAlumni::REGION_FIELD => region,
      IsbfAlumni::CITY_CODE_FIELD => city,
      IsbfAlumni::VISIBLE_FIELD => visible.to_s,
    )
    user
  end

  def distribution(**filters)
    get "/isbf/alumni/distribution.json", params: filters
    expect(response.status).to eq(200), response.body
    response.parsed_body
  end

  it "requires login without exposing counts" do
    alumni
    get "/isbf/alumni/distribution.json"
    expect(response.status).to eq(403), response.body
    expect(response.parsed_body).not_to have_key("total")
  end

  it "allows ordinary members to see aggregate public directory data only" do
    user = alumni
    alumni(visible: false)
    alumni(active: false)
    alumni(approved: false)
    viewer.upsert_custom_fields(IsbfAlumni::VISIBLE_FIELD => "true", IsbfAlumni::COUNTRY_FIELD => "CN")
    sign_in(viewer)

    result = distribution(country: "cn", region: "gd")
    expect(result).to eq(
      "country" => "CN", "region" => "GD", "total" => 1,
      "countries" => [{ "code" => "CN", "count" => 1 }],
      "regions" => [{ "code" => "GD", "count" => 1 }],
      "cities" => [{ "code" => "4403", "count" => 1 }],
    )
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body).not_to include(user.email, user.username, '"users"', '"user_id"')
  end

  it "counts every page, keeps country totals global and provinces independent of the province filter" do
    (IsbfAlumni::PAGE_SIZE + 1).times { alumni }
    alumni(region: "BJ", city: "1101")
    alumni(country: "US", region: "", city: "")
    sign_in(viewer)

    result = distribution(country: "CN", region: "GD", page: 2)
    expect(result.fetch("total")).to eq(IsbfAlumni::PAGE_SIZE + 1)
    expect(result.fetch("countries")).to contain_exactly(
      { "code" => "CN", "count" => IsbfAlumni::PAGE_SIZE + 2 },
      { "code" => "US", "count" => 1 },
    )
    expect(result.fetch("regions")).to contain_exactly(
      { "code" => "GD", "count" => IsbfAlumni::PAGE_SIZE + 1 },
      { "code" => "BJ", "count" => 1 },
    )
    get "/isbf/alumni/directory.json", params: { country: "CN", region: "GD" }
    expect(response.parsed_body.fetch("users").size).to eq(IsbfAlumni::PAGE_SIZE)
    expect(response.parsed_body.fetch("has_more")).to eq(true)
  end

  it "returns no province or city breakdown without a China province selection" do
    alumni
    alumni(country: "US", region: "", city: "")
    sign_in(viewer)
    expect(distribution).to include("total" => 2, "regions" => [], "cities" => [])
    expect(distribution(country: "US")).to include("total" => 1, "regions" => [], "cities" => [])
    expect(distribution(country: "CN")).to include("total" => 1, "cities" => [])
  end

  it "counts profiles with missing or invalid locations in totals without inventing map entries" do
    alumni(city: "")
    alumni(city: "999999")
    alumni(region: "XX", city: "4403")
    alumni(country: "ZZ", region: "", city: "")
    alumni(country: "", region: "", city: "")
    sign_in(viewer)

    expect(distribution).to include("total" => 5, "countries" => [{ "code" => "CN", "count" => 3 }])
    expect(distribution(country: "CN")).to include("total" => 3, "regions" => [{ "code" => "GD", "count" => 2 }])
    expect(distribution(country: "CN", region: "GD")).to include("total" => 2, "cities" => [])
  end

  %w[HK MO TW].each do |legacy|
    it "normalizes legacy #{legacy} consistently with the directory without rewriting profiles" do
      old = alumni(country: legacy, region: "", city: "")
      current = alumni(region: legacy, city: "")
      sign_in(viewer)
      result = distribution(country: "CN", region: legacy)
      expect(result).to include("total" => 2, "regions" => [{ "code" => legacy, "count" => 2 }])
      get "/isbf/alumni/directory.json", params: { country: "CN", region: legacy }
      expect(response.parsed_body.fetch("users")).to contain_exactly(
        include("id" => old.id, "country_code" => "CN", "region_code" => legacy),
        include("id" => current.id, "country_code" => "CN", "region_code" => legacy),
      )
      expect(old.reload.custom_fields[IsbfAlumni::COUNTRY_FIELD]).to eq(legacy)
    end
  end

  it "uses each user's latest location consistently even when custom fields are duplicated" do
    user = alumni
    UserCustomField.create!(user: user, name: IsbfAlumni::REGION_FIELD, value: "BJ")
    UserCustomField.create!(user: user, name: IsbfAlumni::CITY_CODE_FIELD, value: "1101")
    UserCustomField.create!(user: user, name: IsbfAlumni::VISIBLE_FIELD, value: "true")
    sign_in(viewer)

    expect(distribution(country: "CN", region: "GD")).to include("total" => 0, "cities" => [])
    expect(distribution(country: "CN", region: "BJ")).to include(
      "total" => 1, "regions" => [{ "code" => "BJ", "count" => 1 }],
      "cities" => [{ "code" => "1101", "count" => 1 }],
    )
    get "/isbf/alumni/directory.json", params: { country: "CN", region: "BJ" }
    expect(response.parsed_body.fetch("users")).to contain_exactly(
      include("id" => user.id, "region_code" => "BJ", "city_code" => "1101"),
    )
    get "/isbf/alumni/directory.json", params: { country: "CN", region: "GD" }
    expect(response.parsed_body.fetch("users")).to eq([])
  end

  it "reflects visibility, location and membership changes without a shared stale cache" do
    user = alumni
    sign_in(viewer)
    expect(distribution(country: "CN").fetch("total")).to eq(1)
    user.upsert_custom_fields(IsbfAlumni::VISIBLE_FIELD => "false")
    expect(distribution(country: "CN").fetch("total")).to eq(0)
    user.upsert_custom_fields(IsbfAlumni::VISIBLE_FIELD => "true", IsbfAlumni::CITY_CODE_FIELD => "4401")
    expect(distribution(country: "CN", region: "GD").fetch("cities")).to eq([{ "code" => "4401", "count" => 1 }])
    GroupUser.where(group: alumni_group, user: user).delete_all
    expect(distribution.fetch("total")).to eq(0)
  end

  it "returns an available empty directory but rejects a disabled or missing group" do
    sign_in(viewer)
    expect(distribution).to eq("country" => "", "region" => "", "total" => 0, "countries" => [], "regions" => [], "cities" => [])
    SiteSetting.isbf_alumni_enabled = false
    get "/isbf/alumni/distribution.json"
    expect(response.status).to be_in([403, 404])
    SiteSetting.isbf_alumni_enabled = true
    SiteSetting.isbf_alumni_group_name = "missing-alumni"
    get "/isbf/alumni/distribution.json"
    expect(response.status).to eq(403), response.body
  end

  it "rejects malformed, unknown and mismatched filters" do
    sign_in(viewer)
    [{ country: ["CN"] }, { country: "ZZ" }, { region: "GD" }, { country: "US", region: "GD" }, { country: "CN", region: "XX" }, { country: "CN", region: "GD!" }, { country: "CN", region: ["GD"] }].each do |filters|
      get "/isbf/alumni/distribution.json", params: filters
      expect(response.status).to eq(422), response.body
    end
  end

  it "rejects silenced and suspended viewers independently of alumni membership" do
    sign_in(viewer)
    viewer.update!(silenced_till: 1.day.from_now)
    get "/isbf/alumni/distribution.json"
    expect(response.status).to eq(403), response.body
    viewer.update!(silenced_till: nil, suspended_at: Time.current, suspended_till: 1.day.from_now)
    get "/isbf/alumni/distribution.json"
    expect(response.status).to eq(403), response.body
  end

  it "shares the existing directory rate limit" do
    sign_in(viewer)
    RateLimiter.enable
    90.times { get "/isbf/alumni/directory.json" }
    get "/isbf/alumni/distribution.json"
    expect(response.status).to eq(429), response.body
  ensure
    RateLimiter.disable
  end
end
