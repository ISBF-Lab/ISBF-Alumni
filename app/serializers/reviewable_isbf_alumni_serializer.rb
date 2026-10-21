# frozen_string_literal: true

class ReviewableIsbfAlumniSerializer < ReviewableSerializer
  attributes :payload

  def payload
    raise Discourse::InvalidAccess unless IsbfAlumni::Registration.reviewer?(scope.user)
    { application: object.application.public_status.merge(email: object.application.email) }
  end
end
