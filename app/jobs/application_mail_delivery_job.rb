class ApplicationMailDeliveryJob < ActionMailer::MailDeliveryJob
  include PlaygroundJobContext
end
