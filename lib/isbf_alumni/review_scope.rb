# frozen_string_literal: true

module IsbfAlumni
  module ReviewScope
    def viewable_by(user, **options)
      scope = super
      return scope if Registration.reviewer?(user)
      scope.where.not(type: "ReviewableIsbfAlumni")
    end
  end

  module ReviewMetadata
    private

    def render_json_dump(object, *args, **options)
      if !Registration.reviewer?(current_user) && object.is_a?(Hash) && object[:meta].is_a?(Hash)
        object[:meta][:reviewable_types] = Array(object[:meta][:reviewable_types]).reject do |type|
          type.to_s == "ReviewableIsbfAlumni"
        end if object[:meta].key?(:reviewable_types)
      end
      super
    end
  end
end
