# frozen_string_literal: true

Rails.application.config.after_initialize do
  Llm::Config.initialize!
rescue StandardError => e
  Rails.logger.error "Failed to configure RubyLLM: #{e.message}"
end
