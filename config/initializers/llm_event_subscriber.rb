# frozen_string_literal: true

Rails.application.reloader.to_prepare do
  next if Rails.env.test?

  Llm::EventSubscriber.install!
end
