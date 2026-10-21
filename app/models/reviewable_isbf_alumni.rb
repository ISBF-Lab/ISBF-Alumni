# frozen_string_literal: true

class ReviewableIsbfAlumni < Reviewable
  include ReviewableActionBuilder

  def self.additional_args(params)
    { reject_reason: params[:reject_reason] }
  end

  def serializer
    ReviewableIsbfAlumniSerializer
  end

  def build_combined_actions(actions, guardian, _args)
    return unless pending? && can_review_target?(guardian)
    build_action(actions, :approve_alumni, icon: "check", button_class: "btn-primary", source: "isbf_alumni")
    build_action(actions, :reject_alumni, icon: "xmark", require_reject_reason: true, source: "isbf_alumni")
  end

  def perform(performed_by, action_id, args = nil)
    application.with_lock { super }
  end

  def update_fields(params, performed_by, version: nil)
    raise Discourse::InvalidAccess if params.present?
    super
  end

  def perform_approve_alumni(performed_by, _args)
    IsbfAlumni::Registration.approve!(application, performed_by)
    create_result(:success, :approved)
  rescue IsbfAlumni::RegistrationError => error
    failure(error)
  end

  def perform_reject_alumni(performed_by, args)
    IsbfAlumni::Registration.reject!(application, performed_by, args[:reject_reason])
    self.reject_reason = application.rejection_reason
    create_result(:success, :rejected)
  rescue IsbfAlumni::RegistrationError, Discourse::InvalidParameters => error
    failure(error)
  end

  def application
    @application ||= IsbfAlumni::Application.find(payload.fetch("application_id"))
  end

  private

  def can_review_target?(guardian)
    IsbfAlumni::Registration.reviewer?(guardian.user)
  end

  def failure(error)
    create_result(:failure).tap { |result| result.errors = [error.message] }
  end
end
