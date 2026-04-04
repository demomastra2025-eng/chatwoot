require 'ruby_llm'

module Llm::Config
  DEFAULT_MODEL = 'gpt-4.1-mini'.freeze
  OPENAI_DEFAULT_API_BASE = 'https://api.openai.com/v1'.freeze

  class << self
    def initialized?
      @initialized ||= false
    end

    def initialize!
      return if @initialized

      configure_ruby_llm
      @initialized = true
    end

    def reset!
      @initialized = false
    end

    def context(api_key: nil, api_base: nil)
      Llm::ApiClient.context do |config|
        config.openai_api_key = api_key if api_key.present?
        config.openai_api_base = normalize_api_base(api_base) if api_base.present?
      end
    end

    def with_api_key(api_key, api_base: nil)
      yield context(api_key: api_key, api_base: api_base)
    end

    def api_base
      endpoint = openai_endpoint
      return OPENAI_DEFAULT_API_BASE if endpoint.blank?

      normalize_api_base(endpoint)
    end

    private

    def configure_ruby_llm
      Llm::ApiClient.configure do |config|
        config.openai_api_key = system_api_key if system_api_key.present?
        config.openai_api_base = api_base if openai_endpoint.present?
        config.logger = Rails.logger
      end
    end

    def system_api_key
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value
    end

    def openai_endpoint
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value
    end

    def normalize_api_base(value)
      base = value.to_s.chomp('/')
      return OPENAI_DEFAULT_API_BASE if base.blank?

      base.end_with?('/v1') ? base : "#{base}/v1"
    end
  end
end
