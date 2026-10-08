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

  def set_profile(user, country: "CN", region: "GD", city: "ZH", visible:)
    user.upsert_custom_fields(
      IsbfAlumni::DISPLAY_NAME_FIELD => user.name.presence || user.username,
      IsbfAlumni::COUNTRY_FIELD => country,
      IsbfAlumni::REGION_FIELD => region,
      IsbfAlumni::CITY_FIELD => city,
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
    expect(IsbfAlumni::Geography.city(hong_kong, "HK")).to include("name" => "香港")
    expect(IsbfAlumni::Geography.city(macau, "MO")).to include("name" => "澳门")
    expect(IsbfAlumni::Geography.city(guangdong, "HK")).to be_nil
  end
  it "returns only visible alumni profiles while allowing ordinary logged-in users to browse" do
    sign_in(viewer)
    get "/isbf/alumni/directory.json"
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.fetch("users").map { |item| item.fetch("id") }).to eq([member.id])
  end

  it "filters the directory by country, region, and city" do
    sign_in(viewer)
    get "/isbf/alumni/directory.json", params: { country: "CN", region: "GD", city: "ZH" }
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.fetch("users").map { |item| item.fetch("id") }).to eq([member.id])
    expect(response.parsed_body.fetch("users").first).to include(
      "country_code" => "CN",
      "region_code" => "GD",
      "city_code" => "ZH",
      "city_name" => "珠海",
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
    expect(response.parsed_body).to include("country_code" => "CN", "region_code" => "GD", "city_code" => "ZH")

    put "/isbf/alumni/me.json", params: {
      display_name: "校友显示名", country_code: "CN", region_code: "JS", city_code: "SZ",
      industry: "technology", visible: false, username: viewer.username, admin: true,
    }
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body).to include("display_name" => "校友显示名", "region_code" => "JS", "city_code" => "SZ", "visible" => false)
    expect(member.reload.custom_fields[IsbfAlumni::VISIBLE_FIELD]).to eq("false")
    expect(member.reload.username).not_to eq(viewer.username)
    expect(member.admin?).to eq(false)
  end

  it "rejects invalid profiles and prevents non-members from editing" do
    sign_in(member)
    put "/isbf/alumni/me.json", params: {
      display_name: "校友", country_code: "CN", region_code: "ZZ", city_code: "",
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
end
