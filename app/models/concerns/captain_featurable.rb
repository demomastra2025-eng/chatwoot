# frozen_string_literal: true

module CaptainFeaturable
  extend ActiveSupport::Concern
  RUNTIME_DEFAULTS = {
    'privacy_profile' => Llm::OpenRouterWorkspacePolicy::DEFAULT_PRIVACY_PROFILE,
    'assistant_thinking_effort' => 'none',
    'copilot_thinking_effort' => 'none',
    'assistant_moderation' => false,
    'copilot_moderation' => false,
    'moderation_failure_mode' => 'fail_open',
    'assistant_prompt_injection_guardrail' => 'block',
    'copilot_prompt_injection_guardrail' => 'block',
    'assistant_sensitive_info_guardrail' => 'block',
    'copilot_sensitive_info_guardrail' => 'block',
    'trace_input_capture' => !Rails.env.production?,
    'trace_output_capture' => !Rails.env.production?,
    'web_search_enabled' => false,
    'web_scrape_enabled' => false,
    'web_document_parse_enabled' => false,
    'web_search_max_results' => Llm::RuntimePolicy::WEB_SEARCH_DEFAULT_LIMIT,
    'web_scrape_max_chars' => Llm::RuntimePolicy::WEB_SCRAPE_DEFAULT_MAX_CHARS,
    'web_document_parse_max_chars' => Llm::RuntimePolicy::WEB_DOCUMENT_PARSE_DEFAULT_MAX_CHARS,
    'web_allowed_domains' => [],
    'web_blocked_domains' => []
  }.freeze
  RUNTIME_FEATURE_KEYS = %w[assistant copilot].freeze

  included do
    validate :validate_captain_models, if: :captain_models_validation_required?

    # Dynamically define accessor methods for each captain feature
    Llm::Models.feature_keys.each do |feature_key|
      # Define enabled? methods (e.g., captain_editor_enabled?)
      define_method("captain_#{feature_key}_enabled?") do
        captain_features_with_defaults[feature_key]
      end

      # Define model accessor methods (e.g., captain_editor_model)
      define_method("captain_#{feature_key}_model") do
        captain_models_with_defaults[feature_key]
      end
    end

    RUNTIME_FEATURE_KEYS.each do |feature_key|
      define_method("captain_#{feature_key}_thinking_effort") do
        captain_runtime_with_defaults["#{feature_key}_thinking_effort"]
      end

      define_method("captain_#{feature_key}_moderation?") do
        captain_runtime_with_defaults["#{feature_key}_moderation"] == true
      end
    end

    define_method(:captain_trace_input_capture?) do
      captain_runtime_with_defaults['trace_input_capture'] == true
    end

    define_method(:captain_trace_output_capture?) do
      captain_runtime_with_defaults['trace_output_capture'] == true
    end

    define_method(:captain_audio_transcription_prompt) do
      captain_runtime_with_defaults['audio_transcription_prompt'].to_s.strip.presence
    end

    define_method(:captain_knowledge_chunk_size) do
      Captain::KnowledgeSettings.normalize_chunk_size(captain_runtime_with_defaults['knowledge_chunk_size'])
    end
  end

  def captain_preferences
    {
      models: captain_models_with_defaults,
      features: captain_features_with_defaults,
      runtime: captain_runtime_preferences
    }.with_indifferent_access
  end

  def captain_runtime_preferences
    captain_runtime_with_defaults.with_indifferent_access
  end

  private

  def captain_models_with_defaults
    stored_models = captain_models || {}
    Llm::Models.feature_keys.each_with_object({}) do |feature_key, result|
      stored_value = stored_models[feature_key]
      result[feature_key] = resolved_captain_model_for(feature_key, stored_value) ||
                            Llm::Models.default_model_for(feature_key, account: self)
    end
  end

  def captain_features_with_defaults
    stored_features = captain_features || {}
    Llm::Models.feature_keys.index_with do |feature_key|
      if stored_features.key?(feature_key)
        stored_features[feature_key] == true
      elsif feature_key == 'audio_transcription'
        ActiveModel::Type::Boolean.new.cast(audio_transcriptions)
      else
        false
      end
    end
  end

  def captain_runtime_with_defaults
    stored_runtime = captain_runtime || {}
    runtime = Captain::KnowledgeSettings.runtime_defaults.merge(RUNTIME_DEFAULTS).merge(stored_runtime)
    runtime['knowledge_chunk_size'] = Captain::KnowledgeSettings.normalize_chunk_size(runtime['knowledge_chunk_size'])
    runtime
  end

  def validate_captain_models
    return if captain_models.blank?

    captain_models.each do |feature_key, model_name|
      next if model_name.blank?

      resolved_model = resolved_captain_model_for(feature_key, model_name)
      if resolved_model.blank?
        allowed_models = Llm::Models.models_for(feature_key, account: self)
        errors.add(:captain_models, "'#{model_name}' is not a valid model for #{feature_key}. Allowed: #{allowed_models.join(', ')}")
        next
      end

      next if Llm::Models.runtime_supported?(resolved_model, account: self)

      errors.add(:captain_models, "'#{model_name}' for #{feature_key} is not available in RubyLLM.models.")
    end
  end

  def captain_models_validation_required?
    return false if captain_models.blank?
    return true if new_record?
    return false unless will_save_change_to_settings?

    settings_value_for(:captain_models, settings_in_database) != settings_value_for(:captain_models, settings)
  end

  def settings_value_for(key, raw_settings)
    return nil unless raw_settings.respond_to?(:to_h)

    raw_settings.to_h.with_indifferent_access[key]
  end

  def resolved_captain_model_for(feature_key, model_name)
    return if model_name.blank?

    migrated_model = Llm::OpenRouterModelMigration.resolve(model_name, feature: feature_key, account: self)
    candidate = migrated_model.presence || Llm::Models.canonical_model_name(model_name)
    return candidate if Llm::Models.valid_model_for?(feature_key, candidate, account: self)
    return candidate if Llm::Models.configured_model_for_feature?(feature_key, candidate, account: self)
  end
end
