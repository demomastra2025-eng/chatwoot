# frozen_string_literal: true

class Llm::ModerationService
  CheckResult = Struct.new(:status, :feature, :stage, :provider, :model, :reason, :result, keyword_init: true)
  ModerationResult = Struct.new(:flagged, :categories, :reason, :raw, keyword_init: true) do
    def flagged? = flagged == true
  end

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
      provider = moderation_provider_for(account)
      model = moderation_model_for(account)

      return check_result(status: :skipped, feature: feature, stage: stage, reason: :blank_content) if content.blank?
      return check_result(status: :disabled, feature: feature, stage: stage) unless Llm::RuntimePolicy.moderation_enabled?(
        feature: feature,
        account: account,
        preferences: preferences
      )

      if api_key_for(provider, account).blank?
        return handle_unavailable!(
          feature: feature,
          stage: stage,
          reason: :provider_not_configured,
          account: account,
          preferences: preferences
        )
      end

      result = moderation_result_for(
        content: normalized_text(content),
        provider: provider,
        model: model,
        feature: feature,
        stage: stage,
        account: account
      )
      publish_safety_blocked_event(feature: feature, stage: stage, reason: :moderation_flagged) if result.flagged?
      publish_event(
        'moderation.complete',
        status: (result.flagged? ? :flagged : :allowed),
        feature: feature,
        stage: stage,
        provider: provider,
        model: model
      )
      unless result.flagged?
        return check_result(
          status: :allowed,
          feature: feature,
          stage: stage,
          provider: provider,
          model: model,
          result: result
        )
      end

      raise FlaggedContentError.new(feature: feature, stage: stage, result: result)
    rescue RubyLLM::ConfigurationError, RubyLLM::Error => e
      handle_unavailable!(
        feature: feature,
        stage: stage,
        reason: e.class.name.demodulize.underscore,
        account: account,
        preferences: preferences,
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

    def moderation_result_for(content:, provider:, model:, feature:, stage:, account: nil)
      if provider.to_s == 'openrouter'
        return openrouter_moderation_result(content: content, model: model, feature: feature, stage: stage,
                                            account: account)
      end

      with_moderation_context(provider: provider, model: model, account: account) do |context|
        Llm::ApiClient.moderate(content, context: context, model: model, provider: provider)
      end
    end

    def openrouter_moderation_result(content:, model:, feature:, stage:, account: nil)
      unless supports_structured_output?(model, account)
        raise RubyLLM::ConfigurationError, "OpenRouter moderation model #{model} does not support structured output"
      end

      chat = Llm::ChatClient.build(**chat_build_kwargs(model: model, account: account))
      chat = Llm::StructuredOutputPolicy.bind!(chat: chat, schema: openrouter_moderation_schema)
      response = Llm::ChatClient.ask(
        chat,
        openrouter_moderation_prompt(content),
        **chat_ask_kwargs(
          account: account,
          observability: {
            runtime_mode: 'moderation',
            feature_name: 'moderation',
            feature: feature,
            stage: stage,
            provider: 'openrouter',
            model: model
          }
        )
      )
      payload = moderation_payload(response)

      ModerationResult.new(
        flagged: payload[:flagged] == true,
        categories: Array(payload[:categories]).map(&:to_s),
        reason: payload[:reason].to_s,
        raw: payload
      )
    end

    def openrouter_moderation_prompt(content)
      <<~PROMPT.squish
        You are a content safety classifier for a customer support AI system.
        Classify the user-provided content for unsafe, abusive, sexual, self-harm, violence, illegal, or policy-violating material.
        Return JSON only matching the schema. Use flagged=false and categories=[] when the content is safe.

        Content:
        #{content}
      PROMPT
    end

    def openrouter_moderation_schema
      {
        name: 'moderation_result',
        strict: true,
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            flagged: { type: 'boolean' },
            categories: { type: 'array', items: { type: 'string' } },
            reason: { type: 'string' }
          },
          required: %w[flagged categories reason]
        }
      }
    end

    def moderation_payload(response)
      content = response.respond_to?(:content) ? response.content : response
      content = JSON.parse(content) if content.is_a?(String)
      content.with_indifferent_access
    rescue JSON::ParserError, NoMethodError
      raise RubyLLM::Error, 'OpenRouter moderation response was not valid JSON'
    end

    def handle_unavailable!(feature:, stage:, reason:, account:, preferences:, error: nil)
      Rails.logger.warn("[Llm::ModerationService] Moderation unavailable for #{feature}/#{stage}: #{reason}#{": #{error.message}" if error}")
      failure_mode = Llm::RuntimePolicy.moderation_failure_mode(feature: feature, account: account, preferences: preferences)
      provider = moderation_provider_for(account)
      model = moderation_model_for(account)

      publish_event(
        'moderation.unavailable',
        status: :unavailable,
        feature: feature,
        stage: stage,
        provider: provider,
        model: model,
        reason: reason,
        failure_mode: failure_mode
      )
      publish_safety_blocked_event(feature: feature, stage: stage, reason: :moderation_unavailable) if failure_mode == 'fail_closed'

      raise UnavailableError.new(feature: feature, stage: stage, reason: reason) if failure_mode == 'fail_closed'

      check_result(
        status: :skipped,
        feature: feature,
        stage: stage,
        provider: provider,
        model: model,
        reason: reason
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

    def moderation_provider_for(account)
      account.present? ? Llm::Config.moderation_provider(account: account) : Llm::Config.moderation_provider
    end

    def moderation_model_for(account)
      account.present? ? Llm::Config.moderation_model(account: account) : Llm::Config.moderation_model
    end

    def api_key_for(provider, account)
      account.present? ? Llm::Config.api_key(provider, account: account) : Llm::Config.api_key(provider)
    end

    def api_base_for(provider, account)
      account.present? ? Llm::Config.api_base(provider, account: account) : Llm::Config.api_base(provider)
    end

    def supports_structured_output?(model, account)
      account.present? ? Llm::Models.supports_structured_output?(model, account: account) : Llm::Models.supports_structured_output?(model)
    end

    def with_moderation_context(provider:, model:, account:, &)
      kwargs = {
        api_base: api_base_for(provider, account),
        provider: provider,
        model: model
      }
      kwargs[:account] = account if account.present?

      Llm::Config.with_api_key(api_key_for(provider, account), **kwargs, &)
    end

    def chat_build_kwargs(model:, account:)
      { model: model, temperature: 0 }.tap do |kwargs|
        next if account.blank?

        kwargs[:account] = account
        context = chat_context_for(model: model, provider: 'openrouter', account: account)
        kwargs[:context] = context if context.present?
      end
    end

    def chat_context_for(model:, provider:, account:)
      return unless Llm::Config.account_provider_available?(provider, account: account)

      runtime_api_key = api_key_for(provider, account)
      runtime_api_base = api_base_for(provider, account) if Llm::Config.custom_api_base_configured?(provider, account: account)
      return if runtime_api_key.blank? && runtime_api_base.blank?

      Llm::Config.context(
        api_key: runtime_api_key,
        api_base: runtime_api_base,
        provider: provider,
        model: model,
        account: account
      )
    end

    def chat_ask_kwargs(observability:, account:)
      { observability: observability }.tap do |kwargs|
        kwargs[:account] = account if account.present?
      end
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
