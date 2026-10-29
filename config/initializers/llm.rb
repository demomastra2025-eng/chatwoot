# frozen_string_literal: true

require Rails.root.join('lib/llm/open_router_server_tools_patch').to_s
require Rails.root.join('lib/llm/outbound_iin_redactor').to_s

Rails.application.config.after_initialize do
  Llm::Config.initialize!
  if defined?(RubyLLM::Providers::OpenRouter) && !(RubyLLM::Providers::OpenRouter <= Llm::OpenRouterServerToolsPatch)
    RubyLLM::Providers::OpenRouter.prepend(Llm::OpenRouterServerToolsPatch)
  end
  Llm::OutboundIinRedactor.install!
rescue StandardError => e
  Rails.logger.error "Failed to configure RubyLLM: #{e.message}"
end
