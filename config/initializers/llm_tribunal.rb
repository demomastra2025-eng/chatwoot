# frozen_string_literal: true

begin
  require Rails.root.join('lib/llm/evals/tribunal_config').to_s
rescue LoadError
  Rails.logger.debug('ruby_llm-tribunal is unavailable; skipping Tribunal configuration')
else
  Rails.application.config.after_initialize do
    Llm::Evals::TribunalConfig.apply!
  rescue StandardError => e
    Rails.logger.error "Failed to configure RubyLLM Tribunal: #{e.message}"
  end
end
