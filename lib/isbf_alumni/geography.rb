# frozen_string_literal: true

require "digest"

module IsbfAlumni
  module Geography
    DATA_ROOT = File.expand_path("../../assets/geography", __dir__)
    DETAILED_COUNTRY_CODES = %w[CN].freeze
    LEGACY_CHINA_CODES = %w[TW HK MO].freeze
    RETIRED_COUNTRY_NAMES = { "XK" => "科索沃", "EH" => "西撒哈拉" }.freeze

    class << self
      def catalog
        @catalog ||= begin
          data = JSON.parse(File.read(File.join(DATA_ROOT, "catalog.json"), encoding: "UTF-8"))
          data["countries"] = data.fetch("countries").map do |country|
            result = country.slice("code", "name")
            if country["code"] == "CN"
              result["regions"] = country.fetch("regions").map do |region|
                province = region.slice("code", "name")
                if %w[HK MO].include?(region["code"])
                  province["center"] = region.fetch("cities").first.slice("lat", "lng")
                end
                province
              end
            end
            result
          end
          data
        end
      end

      def map_catalog
        @map_catalog ||= begin
          mapped_countries = countries.map do |item|
            next item unless item["code"] == "CN"
            provinces = item.fetch("regions").map do |province|
              province.merge("cities" => city_centers(item["code"], province["code"]))
            end
            item.merge("regions" => provinces)
          end
          catalog.merge("countries" => mapped_countries)
        end
      end

      def city_centers(country_code, region_code)
        return [] unless country_code.to_s.upcase == "CN"
        @city_centers ||= JSON.parse(File.read(File.join(DATA_ROOT, "city-centers.json"), encoding: "UTF-8"))
        @city_centers.fetch(region_code.to_s.upcase, [])
      end

      def countries
        catalog.fetch("countries")
      end

      def country(code)
        countries.find { |item| item["code"] == code.to_s.upcase }
      end

      def region(country, code)
        return nil if code.blank?
        Array(country&.fetch("regions", [])).find { |item| item["code"] == code.to_s.upcase }
      end

      def cities(country_code, region_code)
        return [] unless country_code.to_s.upcase == "CN"
        @cities ||= JSON.parse(File.read(File.join(DATA_ROOT, "cities.json"), encoding: "UTF-8"))
        @cities.fetch(region_code.to_s.upcase, [])
      end

      def city(country_code, region_code, city_code)
        cities(country_code, region_code).find { |item| item["code"] == city_code.to_s }
      end

      def registration_catalog
        countries.map do |item|
          item.merge("regions" => item.fetch("regions", []).map do |province|
            province.merge("cities" => cities(item["code"], province["code"]))
          end)
        end
      end

      def detailed_country_codes
        DETAILED_COUNTRY_CODES
      end

      def normalize_location(country_code, region_code)
        country_code = country_code.to_s.upcase
        region_code = region_code.to_s.upcase
        if LEGACY_CHINA_CODES.include?(country_code)
          ["CN", country_code]
        else
          [country_code, region_code]
        end
      end

      def asset_version(relative_path)
        @asset_versions ||= {}
        @asset_versions[relative_path] ||= Digest::SHA256.file(asset_path(relative_path)).hexdigest
      end

      def asset_url(relative_path)
        "/isbf/alumni/geography/#{relative_path}?v=#{asset_version(relative_path)}"
      end

      def asset_path(relative_path)
        root = File.realpath(DATA_ROOT)
        path = File.realpath(File.join(root, relative_path))
        raise Discourse::NotFound unless path.start_with?("#{root}#{File::SEPARATOR}")
        path
      rescue Errno::ENOENT
        raise Discourse::NotFound
      end
    end
  end
end
