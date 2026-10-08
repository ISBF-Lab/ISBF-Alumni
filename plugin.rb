# frozen_string_literal: true

# name: isbf-alumni
# about: Alumni directory and interactive geography, using native Discourse groups and user custom fields.
# version: 0.1.0
# authors: ISBF Lab
# url: https://github.com/ISBF-Lab/ISBF-Alumni
# required_version: 3.2.0

enabled_site_setting :isbf_alumni_enabled

after_initialize do
  require_relative "lib/isbf_alumni"
  require_relative "lib/isbf_alumni/geography"
  require_relative "lib/isbf_alumni/controllers"

  IsbfAlumni::USER_FIELDS.each do |field|
    register_user_custom_field_type(field, :string, max_length: 256)
  end

  add_to_serializer(:site, :isbf_alumni, include_condition: -> { IsbfAlumni.available? }) do
    IsbfAlumni.site_config
  end

  add_to_serializer(:current_user, :isbf_alumni_member) do
    IsbfAlumni.member?(object)
  end

  IsbfAlumni::Engine.routes.draw do
    get "/" => "alumni#page"
    get "/geography" => "alumni#geography"
    get "/geography/world.geojson" => "alumni#world"
    get "/geography/regions/:country.geojson" => "alumni#regions", constraints: { country: /[A-Z]{2}/ }, format: false
    get "/vendor/leaflet.js" => "alumni#leaflet_js"
    get "/vendor/leaflet.css" => "alumni#leaflet_css"
    get "/vendor/leaflet/images/:image" => "alumni#leaflet_image", constraints: { image: /(?:marker-icon(?:-2x)?|marker-shadow|layers(?:-2x)?).png/ }
    get "/directory" => "alumni#directory"
    get "/me" => "alumni#show_profile"
    put "/me" => "alumni#update_profile"
  end

  Discourse::Application.routes.append do
    mount ::IsbfAlumni::Engine, at: "/isbf/alumni"
  end
end