# frozen_string_literal: true

module IsbfAlumni
  module ReviewScope
    def viewable_by(user, **options)
      scope = super
      return scope if Registration.reviewer?(user)
      scope.where.not(type: "ReviewableIsbfAlumni")
    end
  end
end
