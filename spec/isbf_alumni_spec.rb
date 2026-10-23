# frozen_string_literal: true

require "rails_helper"
require "digest"

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
      "world_map_url" => match(%r{\A/isbf/alumni/geography/world\.geojson\?v=[a-f0-9]+\z}),
      "region_map_urls" => include("CN" => match(%r{\A/isbf/alumni/geography/regions/CN\.geojson\?v=[a-f0-9]+\z})),
    )
  end

  it "keeps Hong Kong and Macau separate from Guangdong" do
    china = IsbfAlumni::Geography.country("CN")
    hong_kong = IsbfAlumni::Geography.region(china, "HK")
    macau = IsbfAlumni::Geography.region(china, "MO")
    guangdong = IsbfAlumni::Geography.region(china, "GD")

    expect(hong_kong).to include("name" => "中国香港")
    expect(macau).to include("name" => "中国澳门")
    expect(hong_kong.fetch("center")).to include("lat" => 22.3193)
    expect(macau.fetch("center")).to include("lat" => 22.1987)
    expect(guangdong).not_to have_key("cities")
  end
  it "exposes provinces only for China and country names elsewhere" do
    sign_in(viewer)
    get "/isbf/alumni/geography.json"
    expect(response.status).to eq(200), response.body
    countries = response.parsed_body.fetch("countries")
    expect(countries.map { |country| country.fetch("code") }).not_to include("TW", "XK", "EH")
    expect(countries.map { |country| country.fetch("code") }).to include("PS")
    expect(countries.find { |country| country["code"] == "CN" }.fetch("regions")).to include(
      include("code" => "TW", "name" => "台湾省"),
    )
    expect(countries.find { |country| country["code"] == "CN" }.fetch("regions")).to all(include("cities" => be_an(Array)))
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

  it "includes legacy Taiwan profiles in China filters without changing stored fields" do
    taiwan_member = Fabricate(:user, active: true, approved: true)
    alumni_group.add(taiwan_member)
    set_profile(member, country: "TW", region: "", visible: true)
    set_profile(taiwan_member, country: "CN", region: "TW", visible: true)
    set_profile(hidden_member, country: "TW", region: "", visible: false)
    set_profile(viewer, country: "TW", region: "", visible: true)
    sign_in(viewer)

    get "/isbf/alumni/directory.json", params: { country: "CN", region: "TW" }
    expect(response.status).to eq(200), response.body
    users = response.parsed_body.fetch("users")
    expect(users.map { |user| user.fetch("id") }).to match_array([member.id, taiwan_member.id])
    expect(users).to all(include("country_code" => "CN", "region_code" => "TW", "region_name" => "台湾省"))

    get "/isbf/alumni/directory.json", params: { country: "CN" }
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body.fetch("users").map { |user| user.fetch("id") }).to match_array([member.id, taiwan_member.id])

    expect(member.reload.custom_fields).to include(IsbfAlumni::COUNTRY_FIELD => "TW", IsbfAlumni::REGION_FIELD => "")
  end

  { "TW" => "台湾省", "HK" => "中国香港", "MO" => "中国澳门" }.each do |legacy_country, region_name|
    it "normalizes legacy #{legacy_country} only when its owner saves" do
      set_profile(member, country: legacy_country, region: "", visible: true)
      sign_in(member)

      get "/isbf/alumni/me.json"
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body).to include("country_code" => "CN", "region_code" => legacy_country)
      expect(member.reload.custom_fields).to include(IsbfAlumni::COUNTRY_FIELD => legacy_country, IsbfAlumni::REGION_FIELD => "")

      get "/isbf/alumni/directory.json", params: { country: "CN", region: legacy_country }
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("users")).to contain_exactly(
        include("id" => member.id, "country_code" => "CN", "region_code" => legacy_country, "region_name" => region_name),
      )

      put "/isbf/alumni/me.json", params: {
        display_name: "校友更新", country_code: "CN", region_code: legacy_country,
        industry: "education", visible: true,
      }
      expect(response.status).to eq(200), response.body
      expect(member.reload.custom_fields).to include(IsbfAlumni::COUNTRY_FIELD => "CN", IsbfAlumni::REGION_FIELD => legacy_country)
    end
  end

  %w[XK EH].each do |excluded_country|
    it "rejects new #{excluded_country} selections while preserving existing profiles on unrelated updates" do
      sign_in(member)
      attributes = {
        display_name: "校友更新", country_code: excluded_country, region_code: "",
        industry: "education", visible: false,
      }
      put "/isbf/alumni/me.json", params: attributes
      expect(response.status).to eq(422), response.body
      expect(member.reload.custom_fields[IsbfAlumni::COUNTRY_FIELD]).to eq("CN")

      set_profile(member, country: excluded_country, region: "", visible: true)
      get "/isbf/alumni/me.json"
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body).to include("country_code" => excluded_country, "visible" => true)
      put "/isbf/alumni/me.json", params: attributes
      expect(response.status).to eq(200), response.body
      expect(member.reload.custom_fields).to include(
        IsbfAlumni::COUNTRY_FIELD => excluded_country,
        IsbfAlumni::DISPLAY_NAME_FIELD => "校友更新",
        IsbfAlumni::VISIBLE_FIELD => "false",
      )
      other_excluded_country = excluded_country == "XK" ? "EH" : "XK"
      put "/isbf/alumni/me.json", params: attributes.merge(country_code: other_excluded_country)
      expect(response.status).to eq(422), response.body
      expect(member.reload.custom_fields[IsbfAlumni::COUNTRY_FIELD]).to eq(excluded_country)
    end
  end

  it "rejects malformed and mismatched Taiwan region filters" do
    sign_in(viewer)
    [{ region: "TW" }, { country: "US", region: "TW" }, { country: "CN", region: "TW!" }, { country: "CN", region: ["TW"] }].each do |filter|
      get "/isbf/alumni/directory.json", params: filter
      expect(response.status).to eq(422), response.body
    end
  end

  it "rejects malformed and foreign Taiwan region profile selections without changing the profile" do
    sign_in(member)
    [{ country_code: "CN", region_code: "TW!" }, { country_code: "CN", region_code: ["TW"] }, { country_code: "US", region_code: "TW" }].each do |location|
      put "/isbf/alumni/me.json", params: {
        display_name: "校友", industry: "education", visible: true,
      }.merge(location)
      expect(response.status).to eq(422), response.body
      expect(member.reload.custom_fields).to include(IsbfAlumni::COUNTRY_FIELD => "CN", IsbfAlumni::REGION_FIELD => "GD")
    end
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
    expect(response.headers["Cache-Control"]).to include("private")
    world = response.parsed_body.fetch("features")
    expect(world.map { |feature| feature.fetch("properties")["country_code"] }).not_to include("TW", "XK", "EH")
    expect(world.map { |feature| feature.fetch("properties")["country_code"] }).to include("PS")
    excluded_outlines = world.select { |feature| feature.fetch("properties").empty? }
    expect(excluded_outlines.length).to eq(2)
    expect(excluded_outlines.map { |feature| feature.fetch("geometry").fetch("coordinates") }).to all(be_present)

    get "/isbf/alumni/geography/regions/CN.geojson"
    expect(response.status).to eq(200), response.body
    expect(response.media_type).to eq("application/json")
    expect(response.body).to include('"code":"GD"')
    expect(response.headers["Cache-Control"]).to include("private")
    taiwan = response.parsed_body.fetch("features").find { |feature| feature.fetch("properties")["code"] == "TW" }
    expect(taiwan).to be_present
    expect(taiwan.fetch("properties")).to include("country_code" => "CN", "name" => "台湾省")
    coordinates = taiwan.fetch("geometry").fetch("coordinates")
    original_digest = "0e5ad71acf5969705a105c8a2f6d25e16e45e77e18ee3b54f0462af46f94a4f7"
    expect(Digest::SHA256.hexdigest(coordinates.flatten.map { |value| format("%.6f", value) }.join(","))).to eq(original_digest)
    china = world.find { |feature| feature.fetch("properties")["country_code"] == "CN" }
    expect(china.fetch("geometry").fetch("type")).to eq("MultiPolygon")
    expect(china.fetch("geometry").fetch("coordinates")).to include(coordinates)
  end

  it "serves the advertised versioned maps through the existing authenticated routes" do
    sign_in(viewer)
    get "/site.json"
    config = response.parsed_body.fetch("isbf_alumni")
    [config.fetch("world_map_url"), config.fetch("region_map_urls").fetch("CN")].each do |url|
      get url
      expect(response.status).to eq(200), response.body
      expect(response.parsed_body.fetch("type")).to eq("FeatureCollection")
      expect(response.headers["Cache-Control"]).to include("private")
    end
  end

  it "changes advertised map versions when asset contents change between releases" do
    geography = IsbfAlumni::Geography
    previous_versions = geography.instance_variable_get(:@asset_versions)
    geography.remove_instance_variable(:@asset_versions) if geography.instance_variable_defined?(:@asset_versions)
    sign_in(viewer)
    get "/site.json"
    expect(response.status).to eq(200), response.body
    original_config = response.parsed_body.fetch("isbf_alumni")

    allow(Digest::SHA256).to receive(:file).and_call_original
    %w[world.geojson regions/CN.geojson].each do |path|
      changed_digest = Digest::SHA256.hexdigest("changed release: #{path}")
      allow(Digest::SHA256).to receive(:file).with(geography.asset_path(path)).and_return(
        double("updated asset digest", hexdigest: changed_digest),
      )
    end
    geography.remove_instance_variable(:@asset_versions) if geography.instance_variable_defined?(:@asset_versions)
    get "/site.json"
    expect(response.status).to eq(200), response.body
    updated_config = response.parsed_body.fetch("isbf_alumni")
    expect(updated_config.fetch("world_map_url")).not_to eq(original_config.fetch("world_map_url"))
    expect(updated_config.fetch("region_map_urls").fetch("CN")).not_to eq(original_config.fetch("region_map_urls").fetch("CN"))
    expect(updated_config.fetch("world_map_url")).to end_with("?v=#{Digest::SHA256.hexdigest("changed release: world.geojson")}")
    expect(updated_config.fetch("region_map_urls").fetch("CN")).to end_with("?v=#{Digest::SHA256.hexdigest("changed release: regions/CN.geojson")}")
  ensure
    geography.instance_variable_set(:@asset_versions, previous_versions)
  end

  it "serves local Leaflet assets without an XHR header" do
    sign_in(viewer)

    get "/isbf/alumni/vendor/leaflet.js"
    expect(response.status).to eq(200), response.body
    expect(response.media_type).to eq("application/javascript")
    expect(response.headers["Cross-Origin-Resource-Policy"]).to eq("same-origin")
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
    %w[geography/world.geojson geography/regions/CN.geojson geography/world.geojson?v=old geography/regions/CN.geojson?v=old vendor/leaflet.js].each do |asset|
      get "/isbf/alumni/#{asset}"
      expect(response.status).not_to eq(200)
      expect(response.body).not_to include('"country_code":"CN"')
    end
  end

  it "rejects a cross-site request for the static map library" do
    sign_in(viewer)
    get "/isbf/alumni/vendor/leaflet.js", headers: { "Sec-Fetch-Site" => "cross-site" }
    expect(response.status).to eq(403)
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
