# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ISBF Alumni city and biography", type: :request do
  fab!(:alumni_group) { Fabricate(:group, name: "alumni") }
  fab!(:member) { Fabricate(:user, active: true, approved: true) }

  before do
    SiteSetting.isbf_alumni_enabled = true
    SiteSetting.isbf_alumni_group_name = "alumni"
    alumni_group.add(member)
  end

  def attributes
    { display_name: "校友", country_code: "CN", region_code: "GD", city_code: "4403", industry: "IT", bio: "介绍\n第二段", visible: true }
  end

  it "persists cities and escaped plain biographies in the owner and directory payloads" do
    sign_in(member)
    put "/isbf/alumni/me.json", params: attributes
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body).to include("city_code" => "4403", "city_name" => "深圳市", "bio" => "介绍\n第二段")
    get "/isbf/alumni/directory.json"
    expect(response.parsed_body.fetch("users")).to include(include("city_name" => "深圳市", "bio" => "介绍\n第二段"))
  end

  it "rejects mismatched cities and biographies over 500 characters without saving" do
    sign_in(member)
    [attributes.merge(region_code: "JS"), attributes.merge(bio: "字" * 501)].each do |input|
      put "/isbf/alumni/me.json", params: input
      expect(response.status).to eq(422), response.body
      expect(member.reload.custom_fields[IsbfAlumni::CITY_CODE_FIELD]).to be_blank
    end
  end

  it "accepts overseas city text and historical profiles with no city or biography" do
    sign_in(member)
    put "/isbf/alumni/me.json", params: attributes.merge(country_code: "US", region_code: "", city_code: "", city_name: " Seattle ", bio: "")
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body).to include("city_name" => "Seattle", "city_code" => "", "bio" => "")
    put "/isbf/alumni/me.json", params: attributes.except(:city_code, :bio)
    expect(response.status).to eq(200), response.body
    expect(response.parsed_body).to include("city_name" => "", "city_code" => "", "bio" => "")
  end

  it "normalizes optional registration geography while checking dependencies" do
    expect(IsbfAlumni.normalize_location({}, required: false)).to eq(country_code: "", region_code: "", city_code: "", city_name: "")
    expect(IsbfAlumni.normalize_location({ country_code: "CN" }, required: false)).to include(region_code: "")
    expect { IsbfAlumni.normalize_location({ city_code: "4403" }, required: false) }.to raise_error(Discourse::InvalidParameters)
    expect { IsbfAlumni.normalize_location({ country_code: "CN", region_code: "JS", city_code: "4403" }, required: false) }.to raise_error(Discourse::InvalidParameters)
  end

  it "imports only optional public fields and keeps the directory hidden" do
    original_name = member.name
    IsbfAlumni.import_registration_profile!(member, attributes.merge(real_name: "Private Legal Name"))
    expect(member.reload.name).to eq(original_name)
    expect(member.custom_fields[IsbfAlumni::DISPLAY_NAME_FIELD]).to be_blank
    expect(IsbfAlumni.profile(member)).to include(visible: false, city_name: "深圳市")
    expect(IsbfAlumni.profile(member)[:display_name]).not_to eq("Private Legal Name")
  end

  it "keeps every current China province covered without changing its ID" do
    provinces = IsbfAlumni::Geography.country("CN").fetch("regions")
    expect(provinces).to all(satisfy { |province| IsbfAlumni::Geography.cities("CN", province["code"]).present? })
    expect(IsbfAlumni::Geography.registration_catalog.find { |country| country["code"] == "CN" }.fetch("regions")).to all(include("cities" => be_present))
  end
end
