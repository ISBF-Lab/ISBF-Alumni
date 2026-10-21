# frozen_string_literal: true

module Jobs
  class IsbfAlumniVerificationEmail < ::Jobs::Base
    def execute(args)
      return unless IsbfAlumni::Registration.enabled?
      data = IsbfAlumni::Registration.challenge(args[:challenge_id])
      return unless data
      mail =
        if data["eligible"]
          IsbfAlumni::Mailer.verification(data.fetch("email"), IsbfAlumni::Registration.verification_code(data))
        else
          IsbfAlumni::Mailer.existing_account(data.fetch("email"))
        end
      Email::Sender.new(mail, "isbf_alumni_verification").send
    rescue StandardError
      raise IsbfAlumni::RegistrationError.new(:email_delivery_failed), cause: nil
    end
  end
end
