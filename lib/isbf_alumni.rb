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

    def directory_scope(country_code: nil, region_code: nil)
      alumni_group = group
      return User.none unless available? && alumni_group

      ids = GroupUser.where(group_id: alumni_group.id).select(:user_id)
      visible_ids = UserCustomField.where(name: VISIBLE_FIELD, value: "true").select(:user_id)
      scope = User.where(id: ids).where(id: visible_ids).where(active: true, approved: true)
      { country: COUNTRY_FIELD, region: REGION_FIELD, city: CITY_CODE_FIELD }.each do |kind, field|
        latest = UserCustomField.where(name: field)
          .select("DISTINCT ON (user_id) user_id, value")
          .order(:user_id, id: :desc)
        scope = scope.joins("LEFT JOIN (#{latest.to_sql}) isbf_alumni_#{kind} ON isbf_alumni_#{kind}.user_id = users.id")
      end
      locations = directory_location_expressions
      scope = scope.where("#{locations[:country]} = ?", country_code) if country_code.present?
      scope = scope.where("#{locations[:region]} = ?", region_code) if region_code.present?
      scope
    end

    def directory_location_expressions
      country = "UPPER(COALESCE(isbf_alumni_country.value, ''))"
      region = "UPPER(COALESCE(isbf_alumni_region.value, ''))"
      legacy = Geography::LEGACY_CHINA_CODES.map { |code| User.connection.quote(code) }.join(", ")
      {
        country: "CASE WHEN #{country} IN (#{legacy}) THEN 'CN' ELSE #{country} END",
        region: "CASE WHEN #{country} IN (#{legacy}) THEN #{country} ELSE #{region} END",
        city: "COALESCE(isbf_alumni_city.value, '')",
      }
    end

    def distribution(country_code:, region_code:)
      locations = directory_location_expressions
      counts = directory_scope.group(*locations.values.map { |sql| Arel.sql(sql) }).count
      countries = Hash.new(0)
      regions = Hash.new(0)
      cities = Hash.new(0)
      total = 0
      china = Geography.country("CN")
      counts.each do |(country, region, city), count|
        selected = (country_code.blank? || country == country_code) && (region_code.blank? || region == region_code)
        total += count if selected
        countries[country] += count if Geography.country(country)
        next unless country_code == "CN" && country == "CN" && Geography.region(china, region)

        regions[region] += count
        if region_code.present? && region == region_code && Geography.city("CN", region, city)
          cities[city] += count
        end
      end
      {
        country: country_code.to_s,
        region: region_code.to_s,
        total: total,
        countries: distribution_entries(countries),
        regions: distribution_entries(regions),
        cities: distribution_entries(cities),
      }
    end

    def distribution_entries(counts)
      counts.sort.map { |code, count| { code: code, count: count } }
    end

    def directory(country_code:, region_code:, page:)
      scope = directory_scope(country_code: country_code, region_code: region_code)
      locations = directory_location_expressions
      scope = scope.select("users.*", *locations.map { |kind, sql| "#{sql} AS alumni_#{kind}_code" })
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
      country_code = user.read_attribute("alumni_country_code")
      region_code = user.read_attribute("alumni_region_code")
      city_code = user.read_attribute("alumni_city_code").to_s
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
        city_code: city_code,
        city_name: country_code == "CN" ? Geography.city(country_code, region_code, city_code)&.fetch("name", "").to_s : fields[CITY_NAME_FIELD].to_s,
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
