# frozen_string_literal: true

module IsbfAlumni
  class Engine < ::Rails::Engine
    engine_name "isbf-alumni"
    isolate_namespace IsbfAlumni
  end

  class AlumniController < ::ApplicationController
    wrap_parameters false
    requires_login
    requires_plugin "isbf-alumni"
    skip_before_action :check_xhr, only: %i[page world regions leaflet_js leaflet_css leaflet_image]
    before_action :ensure_available!

    def page
      render html: "".html_safe, layout: "application"
    end

    def geography
      render json: Geography.catalog
    end

    def world
      send_map_asset("world.geojson", "application/json")
    end

    def regions
      country = params[:country].to_s.upcase
      raise Discourse::NotFound unless Geography.detailed_country_codes.include?(country)
      send_map_asset(File.join("regions", "#{country}.geojson"), "application/json")
    end

    def leaflet_js
      send_vendor_asset("leaflet.js", "application/javascript")
    end

    def leaflet_css
      send_vendor_asset("leaflet.css", "text/css")
    end

    def leaflet_image
      allowed = %w[marker-icon.png marker-icon-2x.png marker-shadow.png layers.png layers-2x.png]
      image = params[:image].to_s
      raise Discourse::NotFound unless allowed.include?(image)
      send_vendor_asset(File.join("images", image), "image/png")
    end

    def directory
      RateLimiter.new(current_user, "isbf-alumni-directory", 90, 1.minute).performed!
      country = code_param(:country, /\A[A-Z]{2}\z/)
      region = code_param(:region, /\A[A-Z0-9]{1,3}\z/)
      city = code_param(:city, /\A[A-Z0-9]{1,5}\z/)
      page_number = params[:page].presence || "1"
      raise Discourse::InvalidParameters.new("page") unless page_number.to_s.match?(/\A[1-9]\d{0,3}\z/)
      page_number = page_number.to_i
      raise Discourse::InvalidParameters.new("page") if page_number > 1000

      selected_country = nil
      selected_region = nil
      if country.present?
        selected_country = Geography.country(country)
        raise Discourse::InvalidParameters.new("country") unless selected_country
      end
      if region.present?
        selected_region = Geography.region(selected_country, region)
        raise Discourse::InvalidParameters.new("region") unless selected_region
      end
      if city.present?
        raise Discourse::InvalidParameters.new("city") unless Geography.city(selected_region, city)
      end

      users, has_more = IsbfAlumni.directory(
        country_code: country,
        region_code: region,
        city_code: city,
        page: page_number,
      )
      render json: { users: users, page: page_number, has_more: has_more }
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
    end

    def show_profile
      IsbfAlumni.ensure_member!(current_user)
      render json: IsbfAlumni.profile(current_user)
    end

    def update_profile
      IsbfAlumni.ensure_member!(current_user)
      RateLimiter.new(current_user, "isbf-alumni-profile", 10, 1.minute).performed!
      profile = IsbfAlumni.update_profile!(current_user, params)
      render json: profile
    rescue Discourse::InvalidParameters => error
      render_json_error(error.message, status: 422)
    end

    private

    def code_param(name, pattern)
      value = params[name]
      return nil if value.blank?
      raise Discourse::InvalidParameters.new(name) unless value.is_a?(String)

      code = value.upcase
      raise Discourse::InvalidParameters.new(name) unless code.match?(pattern)
      code
    end

    def ensure_available!
      raise Discourse::InvalidAccess unless IsbfAlumni.available?
      raise Discourse::InvalidAccess unless current_user&.active? && !current_user.silenced? && !current_user.suspended?
    end

    def send_map_asset(path, content_type)
      send_static_asset(Geography.asset_path(path), content_type)
    end

    def send_vendor_asset(path, content_type)
      vendor_root = File.expand_path("../../assets/vendor/leaflet", __dir__)
      root = File.realpath(vendor_root)
      resolved = File.realpath(File.join(root, path))
      raise Discourse::NotFound unless resolved.start_with?("#{root}#{File::SEPARATOR}")
      send_static_asset(resolved, content_type)
    rescue Errno::ENOENT
      raise Discourse::NotFound
    end

    def send_static_asset(path, content_type)
      send_file path, type: content_type, disposition: "inline"
      response.headers["Cache-Control"] = "private, max-age=3600"
      response.headers["X-Content-Type-Options"] = "nosniff"
    end
  end
end
