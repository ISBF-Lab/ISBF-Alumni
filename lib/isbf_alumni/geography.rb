# frozen_string_literal: true

module IsbfAlumni
  module Geography
    DATA_ROOT = File.expand_path("../../assets/geography", __dir__)
    DETAILED_COUNTRY_CODES = %w[CN].freeze

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

      def detailed_country_codes
        DETAILED_COUNTRY_CODES
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
