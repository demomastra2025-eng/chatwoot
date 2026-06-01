# frozen_string_literal: true

require Rails.root.join('lib/llm/open_router_server_tools_patch').to_s

Rails.application.config.after_initialize do
  Llm::Config.initialize!
  if defined?(RubyLLM::Providers::OpenRouter) && !(RubyLLM::Providers::OpenRouter <= Llm::OpenRouterServerToolsPatch)
    RubyLLM::Providers::OpenRouter.prepend(Llm::OpenRouterServerToolsPatch)
  end
rescue StandardError => e
  Rails.logger.error "Failed to configure RubyLLM: #{e.message}"
end
