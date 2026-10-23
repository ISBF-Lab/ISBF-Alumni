# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfAlumni::Geography do
  it "adds current-ID map centers without changing profile or registration catalogs" do
    source = JSON.parse(described_class.catalog.to_json)
    china = described_class.map_catalog.fetch("countries").find { |country| country["code"] == "CN" }
    guangdong = china.fetch("regions").find { |province| province["code"] == "GD" }
    expect(guangdong.fetch("cities")).to include(
      "code" => "4403", "name" => "深圳市", "lat" => 22.5431, "lng" => 114.0579,
    )
    expect(described_class.catalog).to eq(source)
    expect(described_class.region(described_class.country("CN"), "GD")).not_to have_key("cities")
    expect(described_class.cities("CN", "GD").first.keys).to match_array(%w[code name])
    expect(described_class.city_centers("US", "GD")).to eq([])
    expect(described_class.city_centers("CN", "unknown")).to eq([])
  end

  it "keeps ambiguous centers unavailable while retaining selectable cities" do
    expect(described_class.city("CN", "GX", "4503")).to include("name" => "桂林市")
    expect(described_class.city_centers("CN", "GX").map { |city| city["code"] }).not_to include("4503")
    expect(described_class.city_centers("CN", "TW").size).to eq(22)
  end
end
