# frozen_string_literal: true

# name: isbf-alumni
# about: Alumni directory and interactive geography, using native Discourse groups and user custom fields.
# version: 0.1.1
# authors: ISBF Lab
# url: https://github.com/ISBF-Lab/ISBF-Alumni
# required_version: 3.2.0

enabled_site_setting :isbf_alumni_enabled
register_asset "stylesheets/registration.scss"

after_initialize do
  require_relative "lib/isbf_alumni"
  require_relative "lib/isbf_alumni/geography"
  require_relative "lib/isbf_alumni/controllers"
  require_relative "lib/isbf_alumni/registration"
  require_relative "lib/isbf_alumni/proofs"
  require_relative "lib/isbf_alumni/registration_controller"
  require_relative "lib/isbf_alumni/invitation_metadata"
  require_relative "lib/isbf_alumni/initial_passwords_controller"
  require_relative "app/models/isbf_alumni/application"
  require_relative "app/models/reviewable_isbf_alumni"
  require_relative "app/serializers/reviewable_isbf_alumni_serializer"
  require_relative "app/mailers/isbf_alumni/mailer"
  require_relative "app/jobs/regular/isbf_alumni_verification_email"
  require_relative "app/jobs/regular/isbf_alumni_decision_email"
  require_relative "lib/isbf_alumni/review_scope"

  register_reviewable_type ReviewableIsbfAlumni
  Invite.attr_accessor :isbf_alumni_application_id
  Reviewable.singleton_class.prepend(IsbfAlumni::ReviewScope)
  ReviewablesController.prepend(IsbfAlumni::ReviewMetadata)
  InvitesController.prepend(IsbfAlumni::InvitationMetadata)
  Rails.application.config.filter_parameters += %i[code real_name graduation_year proof_ids]

  IsbfAlumni::USER_FIELDS.each do |field|
    register_user_custom_field_type(field, :string, max_length: field == IsbfAlumni::BIO_FIELD ? 500 : 256)
  end

  add_to_serializer(:site, :isbf_alumni, include_condition: -> { IsbfAlumni.available? }) do
    IsbfAlumni.site_config
  end

  add_to_serializer(:current_user, :isbf_alumni_member) do
    IsbfAlumni.member?(object)
  end

  IsbfAlumni::Engine.routes.draw do
    put "/initial-password" => "initial_passwords#update"
    get "/registration-config" => "registration#configuration"
    post "/applications/email" => "registration#email"
    post "/applications/verify-email" => "registration#verify_email"
    get "/applications/current" => "registration#current"
    post "/applications" => "registration#submit"
    post "/applications/resend" => "registration#resend"
    post "/application-proofs" => "registration#upload"
    get "/application-proofs/:id" => "registration#proof"
    delete "/application-proofs/:id" => "registration#remove_proof"
    get "/" => "alumni#page"
    get "/geography" => "alumni#geography"
    get "/geography/world.geojson" => "alumni#world", format: false
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
