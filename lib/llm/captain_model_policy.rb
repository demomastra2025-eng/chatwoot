# frozen_string_literal: true

# Installation-level egress policy. The model catalog and account preferences
# select candidates; neither can authorize a Captain model not on this list.
class Llm::CaptainModelPolicy
  DEFAULT_MODEL = 'openai/gpt-5.6-luna'
  EGRESS_POLICY_IVAR = :@onelink_captain_egress_policy
  DisallowedModelError = Class.new(ArgumentError)

  # RubyLLM::Chat#ask and tool execution both call #complete. The SDK can also
  # run callbacks between #complete and the actual provider call, so guard both.
  module EgressGuard
    def complete(&)
      Llm::CaptainModelPolicy.guard_chat!(feature: :captain_agent, chat: self)
      super
    end

    private

    def provider_completion(&)
      Llm::CaptainModelPolicy.guard_chat!(feature: :captain_agent, chat: self)
      super
    end
  end

  # RubyLLM's streaming before_message callbacks run while preparing the
  # provider call, after Chat#provider_completion starts. Validate the exact
  # captured SDK arguments again before Provider#complete serializes them.
  module ProviderEgressGuard
    def complete(*args, **kwargs, &)
      chat = instance_variable_get(:@onelink_captain_egress_chat)
      Llm::CaptainModelPolicy.ensure_chat_egress!(feature: :captain_agent, chat: chat)
      model = kwargs[:model]
      model = model.id if model.respond_to?(:id)
      Llm::CaptainModelPolicy.ensure_allowed!(feature: :captain_agent, model: model)
      policy = chat.instance_variable_get(Llm::CaptainModelPolicy::EGRESS_POLICY_IVAR)
      unless policy[:allow_model_fallbacks]
        Llm::CaptainModelPolicy.ensure_fixed_model!(model, policy[:primary_model])
      end
      Llm::CaptainModelPolicy.ensure_wire_models!(
        feature: :captain_agent, params: kwargs[:params],
        primary_model: policy[:primary_model], allow_model_fallbacks: policy[:allow_model_fallbacks]
      )
      super
    end
  end

  class << self
    def guard_chat!(feature:, chat:, model: nil, account: nil)
      return chat unless captain_feature?(feature)

      capture_egress_policy!(chat: chat, feature: feature, model: model, account: account) if chat.is_a?(RubyLLM::Chat)
      ensure_chat_egress!(feature: feature, chat: chat, model: model)
      if chat.is_a?(RubyLLM::Chat)
        chat.singleton_class.prepend(EgressGuard) unless chat.singleton_class.ancestors.include?(EgressGuard)
        provider = chat.instance_variable_get(:@provider)
        if provider.is_a?(RubyLLM::Provider)
          provider.instance_variable_set(:@onelink_captain_egress_chat, chat)
          provider.singleton_class.prepend(ProviderEgressGuard) unless provider.singleton_class.ancestors.include?(ProviderEgressGuard)
        end
      end
      chat
    end

    def ensure_chat_egress!(feature:, chat:, model: nil)
      return unless captain_feature?(feature)

      chat_model = chat.respond_to?(:model) ? chat.model : nil
      chat_model = chat_model.id if chat_model.respond_to?(:id)
      ensure_allowed!(feature: feature, model: chat_model, fallback_models: model)
      policy = chat.instance_variable_get(EGRESS_POLICY_IVAR) if chat.respond_to?(:instance_variable_get)
      if policy && !policy[:allow_model_fallbacks]
        ensure_fixed_model!(chat_model, policy[:primary_model])
      end
      if chat.respond_to?(:params)
        ensure_wire_models!(feature: feature, params: chat.params, primary_model: policy&.dig(:primary_model),
                            allow_model_fallbacks: policy.nil? || policy[:allow_model_fallbacks])
      end
    end

    def ensure_wire_models!(feature:, params:, primary_model: nil, allow_model_fallbacks: true)
      return unless captain_feature?(feature) && !params.nil?

      wire = validated_wire_params(params)
      return unless wire.key?(:model) || wire.key?(:models)

      wire_model_names!(wire).each do |model_name|
        ensure_allowed!(feature: feature, model: model_name)
        ensure_fixed_model!(model_name, primary_model) unless allow_model_fallbacks
      end
    end

    def ensure_fixed_model!(model, primary_model)
      return if Llm::Models.canonical_model_name(model.to_s.strip) == primary_model

      raise DisallowedModelError, 'Captain cross-model fallbacks are disabled for this account'
    end

    def capture_egress_policy!(chat:, feature:, model:, account:)
      # Bind the route before SDK callbacks; late account binding can only
      # narrow an existing snapshot, never restore cross-model fallback.
      current = chat.instance_variable_get(EGRESS_POLICY_IVAR)
      return if current && account.blank?

      selected = egress_policy(feature: feature, chat: chat, model: model, account: account)
      selected = current.merge(allow_model_fallbacks: current[:allow_model_fallbacks] && selected[:allow_model_fallbacks]).freeze if current
      chat.instance_variable_set(EGRESS_POLICY_IVAR, selected)
    end

    def egress_policy(feature:, chat:, model:, account:)
      metadata = Llm::OpenRouterRequestPolicy.routing_metadata(chat)
      selected = model.presence || (chat.model.respond_to?(:id) ? chat.model.id : chat.model)
      source_account = account || metadata[:account]
      account_allows = !source_account || Llm::OpenRouterRoutingProfile.for(
        feature: feature, model: selected, account: source_account
      ).model_fallbacks_allowed?
      compiled_allows = !metadata.key?(:openrouter_allow_model_fallbacks) ||
                        ActiveModel::Type::Boolean.new.cast(metadata[:openrouter_allow_model_fallbacks]) != false
      { primary_model: Llm::Models.canonical_model_name(selected.to_s.strip),
        allow_model_fallbacks: account_allows && compiled_allows }.freeze
    end

    def validated_wire_params(params)
      raise DisallowedModelError, 'Captain wire parameters must be a hash' unless params.is_a?(Hash)

      # Indifferent access silently drops one of these values, but RubyLLM 1.16
      # serializes the original Hash with duplicate JSON keys. Its base payload
      # already has a symbol :model, so even a lone string 'model' is ambiguous.
      %w[model models].each do |key|
        raise DisallowedModelError, "Duplicate Captain wire #{key} keys" if params.keys.count { |raw| raw.to_s == key } > 1
      end
      if params.keys.any? { |key| key != :model && key.to_s == 'model' }
        raise DisallowedModelError, 'Captain wire model must use a symbol key'
      end

      params.with_indifferent_access
    end

    def wire_model_names!(wire)
      raise DisallowedModelError, 'Captain wire model is empty' if wire.key?(:model) && wire[:model].blank?
      if wire.key?(:models) && (!wire[:models].is_a?(Array) || wire[:models].empty?)
        raise DisallowedModelError, 'Captain wire fallback models must be a nonempty array'
      end

      [wire[:model], *Array(wire[:models])].compact
    end

    def allowed_models
      config = InstallationConfig.find_by(name: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')
      return [DEFAULT_MODEL] unless config

      normalize_allowlist(config.value)
    rescue JSON::ParserError
      Rails.logger.error('[LLM] Invalid Captain allowlist JSON; Captain egress disabled')
      []
    end

    def normalize_allowlist(raw)
      models = raw.is_a?(String) ? JSON.parse(raw) : raw
      return [] unless models.is_a?(Array)

      models.filter_map do |model|
        next unless model.is_a?(String)

        Llm::Models.canonical_model_name(model.strip).presence
      end.uniq
    end

    def allowed?(model)
      allowed_models.include?(Llm::Models.canonical_model_name(model.to_s.strip))
    end

    def ensure_allowed!(feature:, model:, fallback_models: nil)
      return unless captain_feature?(feature)

      raise DisallowedModelError, 'Captain model is missing' unless valid_model?(model)

      models = [model, *Array(fallback_models)].flatten.compact
      rejected = models.reject { |candidate| valid_model?(candidate) && allowed?(candidate) }
      raise DisallowedModelError, "Captain model not allowed: #{rejected.map(&:to_s).join(', ')}" if rejected.any?
    end

    def valid_model?(model)
      model.is_a?(String) && model.strip.present?
    end

    def captain_feature?(feature)
      Llm::FeatureProfile.normalize_feature(feature) == 'captain_agent'
    end
  end
end
