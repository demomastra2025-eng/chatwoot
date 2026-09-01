# frozen_string_literal: true

Rails.application.reloader.to_prepare do
  next if Rails.env.test?

  previous_subscriber = Rails.application.config.x[:llm_event_subscriber]
  Rails.application.config.x[:llm_event_subscriber] = Llm::EventSubscriber.install!(
    previous_subscriber: previous_subscriber
  )
end
