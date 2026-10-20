# frozen_string_literal: true

# Whether the platform can send e-mail at all: an invitation to a new user is a letter, and the platform sends letters
# only when the mail server is set up (SMTP_ADDRESS); otherwise the letter goes nowhere and nobody is told (the mailers
# skip it and the errors of the mail server only go to the log). The super admin shows this next to the invitation, so a
# person is never invited into the void: the same condition as ApplicationMailer#smtp_config_set_or_development?.
class SuperAdmin::MailState
  def self.configured?
    ENV['SMTP_ADDRESS'].present? || Rails.env.development?
  end
end
