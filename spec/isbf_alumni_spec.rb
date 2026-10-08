# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ISBF Alumni directory and profiles", type: :request do
  fab!(:alumni_group) { Fabricate(:group, name: "alumni") }
  fab!(:viewer) { Fabricate(:user, active: true, approved: true) }
  fab!(:member) { Fabricate(:user, active: true, approved: true) }
  fab!(:hidden_member) { Fabricate(:user, active: true, approved: true) }

  before do
    SiteSetting.isbf_alumni_enabled = true
    SiteSetting.isbf_alumni_group_name = "alumni"
    alumni_group.add(member)
    alumni_group.add(hidden_member)
    set_profile(member, visible: true)
    set_profile(hidden_member, visible: false)
  end

  def set_profile(user, country: "CN", region: "GD", visible:)
    user.upsert_custom_fields(
      IsbfAlumni::DISPLAY_NAME_FIELD => user.name.presence || user.username,
      IsbfAlumni::COUNTRY_FIELD => country,
      IsbfAlumni::REGION_FIELD => region,
      IsbfAlumni::INDUSTRY_FIELD => "education",
      IsbfAlumni::VISIBLE_FIELD => visible ? "true" : "false",
    )
  end

  it "requires a logged-in session for the directory" do
    get "/isbf/alumni/directory.json"
    expect(response.status).to eq(403), response.body
    expect(response.parsed_body).to include("error_type" => "not_logged_in")
  end

  it "advertises the capability only when the native alumni group exists" do
    sign_in(viewer)
    get "/site.json"
    expect(response.status).to eq(200), response.body
    capability = response.parsed_body.fetch("isbf_alumni")
    expect(capability.fetch("countries").first.keys).to match_array(%w[code name])
    expect(capability.fetch("region_map_urls").keys).to eq(["CN"])
    expect(capability).to include(
      "enabled" => true,
      "default_country" => "CN",
      "world_map_url" => "/isbf/alumni/geography/world.geojson",
      "region_map_urls" => include("CN" => "/isbf/alumni/geography/regions/CN.geojson"),
    )
  end

  it "keeps Hong Kong and Macau separate from Guangdong" do
    china = IsbfAlumni::Geography.country("CN")
    hong_kong = IsbfAlumni::Geography.region(china, "HK")
    macau = IsbfAlumni::Geography.region(china, "MO")
    guangdong = IsbfAlumni::Geography.region(china, "GD")

    expect(hong_kong).to include("name" => "香港特别行政区")
    expect(macau).to include("name" => "澳门特别行政区")
    expect(hong_kong.fetch("center")).to include("lat" => 22.3193)
    expect(macau.fetch("center")).to include("lat" => 22.1987)
    expect(guangdong).not_to have_key("cities")
  end
  it "exposes provinces only for China and country names elsewhere" do
    sign_in(viewer)
    get "/isbf/alumni/geography.json"
    expect(response.status).to eq(200), response.body
    countries = response.parsed_body.fetch("countries")
    expect(countries.find { |country| country["code"] == "CN" }.fetch("regions")).to all(satisfy { |region| !region.key?("cities") })
    expect(countries.reject { |country| country["code"] == "CN" }).to all(satisfy { |country| country.keys.sort == %w[code name] })
    get "/isbf/alumni/geography/regions/US.geojson"
    expect(response.status).to eq(404)
  end

  it "returns only visible alumni profiles while allowing ordinary logged-in users to browse" do
    sign_in(viewer)
    get "/isbf/alumni/directory.json"
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.fetch("users").map { |item| item.fetch("id") }).to eq([member.id])
  end

  it "filters the directory by country and province" do
    sign_in(viewer)
    get "/isbf/alumni/directory.json", params: { country: "CN", region: "GD" }
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.fetch("users").map { |item| item.fetch("id") }).to eq([member.id])
    expect(response.parsed_body.fetch("users").first).to include(
      "country_code" => "CN",
      "region_code" => "GD",
    )
  end

  it "rejects unknown geographic filter values" do
    sign_in(viewer)
    get "/isbf/alumni/directory.json", params: { country: "CN", region: "XX" }
    expect(response.status).to eq(422), response.body
  end

  it "allows a member to read and update only their own profile" do
    sign_in(member)
    get "/isbf/alumni/me.json"
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body).to include("country_code" => "CN", "region_code" => "GD")

    put "/isbf/alumni/me.json", params: {
      display_name: "校友显示名", country_code: "CN", region_code: "JS",
      industry: "technology", visible: false, username: viewer.username, admin: true,
    }
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body).to include("display_name" => "校友显示名", "region_code" => "JS", "visible" => false)
    expect(member.reload.custom_fields[IsbfAlumni::VISIBLE_FIELD]).to eq("false")
    expect(member.reload.username).not_to eq(viewer.username)
    expect(member.admin?).to eq(false)
  end

  it "rejects invalid profiles and prevents non-members from editing" do
    sign_in(member)
    put "/isbf/alumni/me.json", params: {
      display_name: "校友", country_code: "CN", region_code: "ZZ",
      industry: "education", visible: true,
    }
    expect(response.status).to eq(422), response.body

    sign_in(viewer)
    put "/isbf/alumni/me.json", params: {
      display_name: "Viewer", country_code: "CN", region_code: "GD", city_code: "ZH",
      industry: "education", visible: true,
    }
    expect(response.status).to eq(403), response.body
  end

  it "requires membership before reading profile settings" do
    sign_in(viewer)
    get "/isbf/alumni/me.json"
    expect(response.status).to eq(403), response.body
  end

  it "serves the authenticated world map and region assets" do
    sign_in(viewer)
    get "/isbf/alumni/geography/world.geojson"
    expect(response.status).to eq(200), response.body
    expect(response.media_type).to eq("application/json")
    expect(response.body).to include('"country_code":"CN"')

    get "/isbf/alumni/geography/regions/CN.geojson"
    expect(response.status).to eq(200), response.body
    expect(response.media_type).to eq("application/json")
    expect(response.body).to include('"code":"GD"')
  end

  it "serves local Leaflet assets without an XHR header" do
    sign_in(viewer)

    get "/isbf/alumni/vendor/leaflet.js"
    expect(response.status).to eq(200), response.body
    expect(response.media_type).to eq("application/javascript")
    expect(response.body).to include("Leaflet")

    get "/isbf/alumni/vendor/leaflet.css"
    expect(response.status).to eq(200), response.body
    expect(response.media_type).to eq("text/css")
    expect(response.body).to include(".leaflet-container")

    get "/isbf/alumni/vendor/leaflet/images/marker-icon.png"
    expect(response.status).to eq(200), response.body
    expect(response.media_type).to eq("image/png")
    expect(response.body.b).to start_with("\x89PNG\r\n\x1A\n".b)
  end

  it "keeps map and Leaflet assets behind login" do
    %w[geography/world.geojson vendor/leaflet.js].each do |asset|
      get "/isbf/alumni/#{asset}"
      expect(response.status).not_to eq(200)
      expect(response.body).not_to include('"country_code":"CN"')
    end
  end
end

RSpec.describe "ISBF Alumni access changes", type: :request do
  fab!(:alumni_group) { Fabricate(:group, name: "alumni") }
  fab!(:member) { Fabricate(:user, active: true, approved: true) }

  before do
    SiteSetting.isbf_alumni_enabled = true
    SiteSetting.isbf_alumni_group_name = "alumni"
    alumni_group.add(member)
    member.upsert_custom_fields(IsbfAlumni::VISIBLE_FIELD => "true", IsbfAlumni::COUNTRY_FIELD => "CN")
  end

  it "stops publishing and updating a profile after membership is removed" do
    sign_in(member)
    GroupUser.where(group: alumni_group, user: member).delete_all
    get "/isbf/alumni/directory.json"
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.fetch("users")).to be_empty
    get "/isbf/alumni/me.json"
    expect(response.status).to eq(403)
  end

  it "rejects profile updates for a silenced member" do
    sign_in(member)
    member.update!(silenced_till: 1.day.from_now)
    put "/isbf/alumni/me.json", params: {
      display_name: "Member", country_code: "CN", region_code: "GD",
      industry: "education", visible: true,
    }
    expect(response.status).to eq(403), response.body
  end
end
