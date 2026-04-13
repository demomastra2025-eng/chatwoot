# frozen_string_literal: true

class Llm::ModerationService
  CheckResult = Struct.new(:status, :feature, :stage, :provider, :model, :reason, :result, keyword_init: true)

  class FlaggedContentError < StandardError
    attr_reader :feature, :stage, :result

    def initialize(feature:, stage:, result:)
      @feature = feature
      @stage = stage
      @result = result

      super("Moderation flagged #{feature} #{stage}")
    end
  end

  class UnavailableError < StandardError
    attr_reader :feature, :stage, :reason

    def initialize(feature:, stage:, reason:)
      @feature = feature
      @stage = stage
      @reason = reason

      super("Moderation unavailable for #{feature} #{stage}: #{reason}")
    end
  end

  MAX_CONTENT_LENGTH = 10_000
  class << self
    def check!(feature:, stage:, content:, account: nil, preferences: nil)
      provider = Llm::Config.moderation_provider
      model = Llm::Config.moderation_model

      return check_result(status: :skipped, feature:, stage:, reason: :blank_content) if content.blank?
      return check_result(status: :disabled, feature:, stage:) unless Llm::RuntimePolicy.moderation_enabled?(
        feature: feature,
        account: account,
        preferences: preferences
      )
      return handle_unavailable!(
        feature:,
        stage:,
        reason: :provider_not_configured,
        account:,
        preferences:
      ) if Llm::Config.api_key(provider).blank?

      result = Llm::ApiClient.moderate(
        normalized_text(content),
        model: model,
        provider: provider
      )
      publish_safety_blocked_event(feature:, stage:, reason: :moderation_flagged) if result.flagged?
      publish_event(
        'moderation.complete',
        status: (result.flagged? ? :flagged : :allowed),
        feature:,
        stage:,
        provider: provider,
        model: model
      )
      return check_result(
        status: :allowed,
        feature:,
        stage:,
        provider: provider,
        model: model,
        result:
      ) unless result.flagged?

      raise FlaggedContentError.new(feature: feature, stage: stage, result: result)
    rescue RubyLLM::ConfigurationError, RubyLLM::Error => e
      handle_unavailable!(
        feature:,
        stage:,
        reason: e.class.name.demodulize.underscore,
        account:,
        preferences:,
        error: e
      )
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

    private

    def handle_unavailable!(feature:, stage:, reason:, account:, preferences:, error: nil)
      Rails.logger.warn("[Llm::ModerationService] Moderation unavailable for #{feature}/#{stage}: #{reason}#{": #{error.message}" if error}")
      failure_mode = Llm::RuntimePolicy.moderation_failure_mode(feature:, account:, preferences:)
      provider = Llm::Config.moderation_provider
      model = Llm::Config.moderation_model

      publish_event(
        'moderation.unavailable',
        status: :unavailable,
        feature:,
        stage:,
        provider: provider,
        model: model,
        reason:,
        failure_mode:
      )
      publish_safety_blocked_event(feature:, stage:, reason: :moderation_unavailable) if failure_mode == 'fail_closed'

      raise UnavailableError.new(feature:, stage:, reason:) if failure_mode == 'fail_closed'

      check_result(
        status: :skipped,
        feature:,
        stage:,
        provider: provider,
        model: model,
        reason:
      )
    end

    def check_result(status:, feature:, stage:, provider: nil, model: nil, reason: nil, result: nil)
      CheckResult.new(
        status: status,
        feature: feature.to_sym,
        stage: stage.to_sym,
        provider: provider,
        model: model,
        reason: reason&.to_sym,
        result: result
      )
    end

    def publish_event(event_name, **payload)
      Llm::EventBus.publish(event_name, payload)
    end

    def publish_safety_blocked_event(feature:, stage:, reason:)
      Llm::EventBus.publish(
        'safety.blocked',
        feature: feature.to_sym,
        stage: stage.to_sym,
        reason: reason.to_sym
      )
    end
  end
end
