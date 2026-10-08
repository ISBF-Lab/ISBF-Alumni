# frozen_string_literal: true

module IsbfAlumni
  module Geography
    DATA_ROOT = File.expand_path("../../assets/geography", __dir__)
    DETAILED_COUNTRY_CODES = %w[CN US CA GB AU JP DE FR].freeze

    class << self
      def catalog
        @catalog ||= JSON.parse(File.read(File.join(DATA_ROOT, "catalog.json"), encoding: "UTF-8"))
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

      def city(region, code)
        return nil if code.blank?
        Array(region&.fetch("cities", [])).find { |item| item["code"] == code.to_s.upcase }
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