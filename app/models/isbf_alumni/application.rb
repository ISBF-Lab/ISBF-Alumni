# frozen_string_literal: true

module IsbfAlumni
  class Application < ActiveRecord::Base
    self.table_name = "isbf_alumni_applications"

    belongs_to :invite, optional: true
    belongs_to :user, optional: true
    belongs_to :reviewed_by, class_name: "User", optional: true
    belongs_to :reviewable, optional: true

    validates :email, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 254 }
    validates :status, inclusion: { in: %w[draft pending approved rejected registered] }
    validates :real_name, length: { maximum: 80 }
    validates :rejection_reason, length: { maximum: 2000 }
    validates :mail_status, inclusion: { in: %w[none pending sent failed] }

    after_commit :enqueue_decision_email

    def editable?
      status.in?(%w[draft rejected])
    end

    def public_status
      country = Geography.country(profile["country_code"])
      region = Geography.region(country, profile["region_code"])
      city = Geography.city(profile["country_code"], profile["region_code"], profile["city_code"])
      {
        id: id,
        status: status,
        real_name: real_name.to_s,
        graduation_year: graduation_year,
        **profile.symbolize_keys,
        country_name: country&.fetch("name", "").to_s,
        region_name: region&.fetch("name", "").to_s,
        city_display_name: city&.fetch("name", nil) || profile["city_name"].to_s,
        proofs: submitted_proofs,
        rejection_reason: rejection_reason.to_s,
        mail_status: mail_status,
      }
    end

    def submitted_proofs
      selected = submitted_proof_ids
      proofs.filter_map do |proof|
        next if proof["removed_at"].present?
        next unless selected.include?(proof["id"]) || (editable? && !proof["bound"])
        {
          id: proof.fetch("id"),
          bytes: proof.fetch("bytes"),
          bound: proof["bound"] == true,
          url: "/isbf/alumni/application-proofs/#{proof.fetch('id')}",
        }
      end
    end

    private

    def enqueue_decision_email
      return unless previous_changes.key?("mail_version") && mail_status == "pending"
      Jobs.enqueue(:isbf_alumni_decision_email, application_id: id, version: mail_version)
    end
  end
end
