# frozen_string_literal: true

module Jobs
  class IsbfAlumniDecisionEmail < ::Jobs::Base
    def execute(args)
      application = IsbfAlumni::Application.find_by(id: args[:application_id])
      return unless application
      failed = false
      application.with_lock do
        next unless application.mail_version == args[:version].to_i && application.mail_status != "sent"
        next unless application.status.in?(%w[approved rejected])
        begin
          if SiteSetting.disable_emails != "no" ||
               (application.status == "approved" && !application.invite&.redeemable?)
            raise IsbfAlumni::RegistrationError.new(:email_delivery_failed)
          end
          Email::Sender.new(IsbfAlumni::Mailer.decision(application), "isbf_alumni_decision").send
          application.update!(mail_status: "sent", last_mailed_at: Time.current)
        rescue StandardError
          application.update!(mail_status: "failed")
          failed = true
        end
      end
      raise IsbfAlumni::RegistrationError.new(:email_delivery_failed), cause: nil if failed
    end
  end
end
