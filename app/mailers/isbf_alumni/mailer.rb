# frozen_string_literal: true

module IsbfAlumni
  class Mailer < ::ActionMailer::Base
    include Email::BuildEmailHelper

    def verification(email, code)
      build_notice(email, "verification", code: code)
    end

    def existing_account(email)
      build_notice(email, "existing_account", login_url: "#{Discourse.base_url}/login")
    end

    def decision(application)
      if application.status == "approved"
        build_notice(application.email, "approved", link: application.invite.link(with_email_token: true))
      else
        build_notice(
          application.email, "rejected", reason: application.rejection_reason,
          link: "#{Discourse.base_url}/login?mode=register&alumni=1",
        )
      end
    end

    private

    def build_notice(email, kind, **values)
      values[:site_name] = SiteSetting.title
      build_email(
        email,
        subject: I18n.t("isbf_alumni.emails.#{kind}.subject", **values),
        body: I18n.t("isbf_alumni.emails.#{kind}.body", **values),
      )
    end
  end
end
