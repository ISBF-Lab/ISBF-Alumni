# frozen_string_literal: true

require "json"

module IsbfAlumni
  GROUP_NAME_SETTING = :isbf_alumni_group_name
  DEFAULT_GROUP_NAME = "alumni"
  PAGE_SIZE = 20
  PROFILE_FIELDS = %w[display_name country_code region_code city_code city_name industry bio visible].freeze
  USER_FIELDS = %w[
    isbf_alumni_display_name
    isbf_alumni_country
    isbf_alumni_region
    isbf_alumni_city_code
    isbf_alumni_city_name
    isbf_alumni_bio
    isbf_alumni_industry
    isbf_alumni_visible
  ].freeze

  DISPLAY_NAME_FIELD = "isbf_alumni_display_name"
  COUNTRY_FIELD = "isbf_alumni_country"
  REGION_FIELD = "isbf_alumni_region"
  CITY_CODE_FIELD = "isbf_alumni_city_code"
  CITY_NAME_FIELD = "isbf_alumni_city_name"
  BIO_FIELD = "isbf_alumni_bio"
  INDUSTRY_FIELD = "isbf_alumni_industry"
  VISIBLE_FIELD = "isbf_alumni_visible"

  class << self
    def enabled?
      SiteSetting.isbf_alumni_enabled
    end

    def group
      Group.find_by(name: SiteSetting.public_send(GROUP_NAME_SETTING).presence || DEFAULT_GROUP_NAME)
    end

    def available?
      enabled? && group.present?
    end

    def member?(user)
      return false unless user && (alumni_group = group)
      GroupUser.exists?(group_id: alumni_group.id, user_id: user.id)
    end

    def site_config
      {
        enabled: available?,
        registration_enabled: Registration.enabled?,
        default_country: Geography.catalog["default_country"],
        countries: Geography.catalog["countries"].map { |country| country.slice("code", "name") },
        cities: Geography.country("CN").fetch("regions").to_h { |region| [region["code"], Geography.cities("CN", region["code"])] },
        geography_url: "/isbf/alumni/geography",
        world_map_url: Geography.asset_url("world.geojson"),
        region_map_urls: Geography.detailed_country_codes.to_h do |code|
          [code, Geography.asset_url("regions/#{code}.geojson")]
        end,
        leaflet_js_url: "/isbf/alumni/vendor/leaflet.js",
        leaflet_css_url: "/isbf/alumni/vendor/leaflet.css",
      }
    end

    def ensure_member!(user)
      raise Discourse::InvalidAccess unless available? && member?(user)
    end

    def profile(user)
      fields = user.custom_fields || {}
      country_code, region_code = Geography.normalize_location(fields[COUNTRY_FIELD], fields[REGION_FIELD])
      {
        display_name: fields[DISPLAY_NAME_FIELD].presence || user.name.presence || user.username,
        country_code: country_code,
        region_code: region_code,
        city_code: fields[CITY_CODE_FIELD].to_s,
        city_name: country_code == "CN" ? Geography.city(country_code, region_code, fields[CITY_CODE_FIELD])&.fetch("name", "").to_s : fields[CITY_NAME_FIELD].to_s,
        bio: fields[BIO_FIELD].to_s,
        industry: fields[INDUSTRY_FIELD].to_s,
        visible: fields[VISIBLE_FIELD].to_s == "true",
      }
    end

    def update_profile!(user, attributes)
      ensure_member!(user)
      input =
        if attributes.respond_to?(:permit)
          attributes.permit(*PROFILE_FIELDS).to_h.stringify_keys
        else
          attributes.to_h.stringify_keys.slice(*PROFILE_FIELDS)
        end
      location = normalize_location(input)
      country_code = location[:country_code]
      fields = user.custom_fields || {}
      if Geography::RETIRED_COUNTRY_NAMES.key?(country_code) && fields[COUNTRY_FIELD].to_s.upcase != country_code
        raise Discourse::InvalidParameters.new("country_code")
      end
      display_name = text(input["display_name"], 60, required: true)
      industry = text(input["industry"], 60, required: true)
      bio = text(input["bio"], 500, required: false)

      visible = boolean(input["visible"])
      user.upsert_custom_fields(
        DISPLAY_NAME_FIELD => display_name,
        COUNTRY_FIELD => country_code,
        REGION_FIELD => location[:region_code],
        CITY_CODE_FIELD => location[:city_code],
        CITY_NAME_FIELD => location[:city_name],
        BIO_FIELD => bio,
        INDUSTRY_FIELD => industry,
        VISIBLE_FIELD => visible ? "true" : "false",
      )
      profile(user)
    end

    def normalize_location(attributes, required: true)
      input = attributes.to_h.stringify_keys
      %w[country_code region_code city_code city_name].each do |key|
        raise Discourse::InvalidParameters.new(key) if input[key].present? && !input[key].is_a?(String)
      end
      country_code, region_code = Geography.normalize_location(input["country_code"], input["region_code"])
      city_code = input["city_code"].to_s.strip
      city_name = text(input["city_name"], 80, required: false)
      if country_code.blank? && !required
        raise Discourse::InvalidParameters.new("country_code") if region_code.present? || city_code.present? || city_name.present?
        return { country_code: "", region_code: "", city_code: "", city_name: "" }
      end
      country = Geography.country(country_code)
      retired = required && Geography::RETIRED_COUNTRY_NAMES.key?(country_code)
      raise Discourse::InvalidParameters.new("country_code") unless country || retired
      regions = country&.fetch("regions", []) || []
      if region_code.present?
        raise Discourse::InvalidParameters.new("region_code") unless Geography.region(country, region_code)
      elsif required && regions.any?
        raise Discourse::InvalidParameters.new("region_code")
      end
      if country_code == "CN"
        if city_code.present? && !Geography.city(country_code, region_code, city_code)
          raise Discourse::InvalidParameters.new("city_code")
        end
        city_name = ""
      elsif city_code.present?
        raise Discourse::InvalidParameters.new("city_code")
      end
      { country_code: country_code, region_code: region_code, city_code: city_code, city_name: city_name }
    end

    def import_registration_profile!(user, attributes)
      ensure_member!(user)
      input = attributes.to_h.stringify_keys
      location = normalize_location(input, required: false)
      user.upsert_custom_fields(
        COUNTRY_FIELD => location[:country_code],
        REGION_FIELD => location[:region_code],
        CITY_CODE_FIELD => location[:city_code],
        CITY_NAME_FIELD => location[:city_name],
        INDUSTRY_FIELD => text(input["industry"], 60, required: false),
        BIO_FIELD => text(input["bio"], 500, required: false),
        VISIBLE_FIELD => "false",
      )
      profile(user)
    end

    def directory(country_code:, region_code:, page:)
      alumni_group = group
      return [] unless available? && alumni_group

      ids = GroupUser.where(group_id: alumni_group.id).select(:user_id)
      visible_ids = UserCustomField.where(name: VISIBLE_FIELD, value: "true").select(:user_id)
      scope = User.where(id: ids).where(id: visible_ids).where(active: true, approved: true)

      if country_code.present?
        current_location = scope.where(
          id: UserCustomField.where(name: COUNTRY_FIELD, value: country_code).select(:user_id),
        )
        if region_code.present?
          current_location = current_location.where(
            id: UserCustomField.where(name: REGION_FIELD, value: region_code).select(:user_id),
          )
        end
        legacy_codes = if country_code == "CN" && region_code.blank?
          Geography::LEGACY_CHINA_CODES
        elsif country_code == "CN" && Geography::LEGACY_CHINA_CODES.include?(region_code)
          [region_code]
        else
          []
        end
        scope = if legacy_codes.any?
          legacy_location = scope.where(
            id: UserCustomField.where(name: COUNTRY_FIELD, value: legacy_codes).select(:user_id),
          )
          current_location.or(legacy_location)
        else
          current_location
        end
      end
      users = scope.order(:id).offset((page - 1) * PAGE_SIZE).limit(PAGE_SIZE + 1).to_a
      has_more = users.length > PAGE_SIZE
      users = users.first(PAGE_SIZE)
      User.preload_custom_fields(users, USER_FIELDS)

      [
        users.map { |user| directory_entry(user) },
        has_more,
      ]
    end

    def directory_entry(user)
      fields = user.preloaded_custom_fields || {}
      country_code, region_code = Geography.normalize_location(fields[COUNTRY_FIELD], fields[REGION_FIELD])
      country = Geography.country(country_code)
      region = country && Geography.region(country, region_code)

      {
        id: user.id,
        username: user.username,
        display_name: fields[DISPLAY_NAME_FIELD].presence || user.name.presence || user.username,
        country_code: country_code,
        country_name: country&.fetch("name", nil) || Geography::RETIRED_COUNTRY_NAMES[country_code],
        region_code: region_code,
        region_name: region&.fetch("name", nil),
        city_code: fields[CITY_CODE_FIELD].to_s,
        city_name: country_code == "CN" ? Geography.city(country_code, region_code, fields[CITY_CODE_FIELD])&.fetch("name", "").to_s : fields[CITY_NAME_FIELD].to_s,
        bio: fields[BIO_FIELD].to_s,
        industry: fields[INDUSTRY_FIELD].to_s,
      }
    end

    def text(value, max_length, required:)
      normalized = value.is_a?(String) ? value.strip : ""
      raise Discourse::InvalidParameters.new("profile") if (required && normalized.blank?) || normalized.length > max_length
      normalized
    end

    def boolean(value)
      return true if value == true || %w[true 1].include?(value.to_s)
      return false if value == false || %w[false 0].include?(value.to_s)
      raise Discourse::InvalidParameters.new("visible")
    end
  end
end
