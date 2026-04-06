# frozen_string_literal: true

class Llm::ModerationService
  class FlaggedContentError < StandardError
    attr_reader :feature, :stage, :result

    def initialize(feature:, stage:, result:)
      @feature = feature
      @stage = stage
      @result = result

      super("Moderation flagged #{feature} #{stage}")
    end
  end

  MAX_CONTENT_LENGTH = 10_000

  class << self
    def check!(feature:, stage:, content:, account: nil, preferences: nil)
      return if content.blank?
      return unless Llm::RuntimePolicy.moderation_enabled?(
        feature: feature,
        account: account,
        preferences: preferences
      )
      return if Llm::Config.api_key('openai').blank?

      result = Llm::ApiClient.moderate(
        normalized_text(content),
        model: Llm::Config.moderation_model,
        provider: 'openai'
      )
      return result unless result.flagged?

      raise FlaggedContentError.new(feature: feature, stage: stage, result: result)
    rescue RubyLLM::ConfigurationError, RubyLLM::Error => e
      Rails.logger.warn("[Llm::ModerationService] Skipping moderation for #{feature}/#{stage}: #{e.class}: #{e.message}")
      nil
    end

    def normalized_text(content)
      text =
        case content
        when RubyLLM::Content
          content.text
        when Array
          content.filter_map do |part|
            part = part.with_indifferent_access if part.respond_to?(:with_indifferent_access)
            next part[:text] if part.is_a?(Hash) && part[:type].to_s == 'text'

            nil
          end.join("\n")
        else
          content.to_s
        end

      text.to_s.first(MAX_CONTENT_LENGTH)
    end
  end
end
