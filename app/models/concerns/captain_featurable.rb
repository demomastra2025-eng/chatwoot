# frozen_string_literal: true

module CaptainFeaturable
  extend ActiveSupport::Concern
  RUNTIME_DEFAULTS = {
    'assistant_thinking_effort' => 'none',
    'copilot_thinking_effort' => 'none',
    'assistant_moderation' => true,
    'copilot_moderation' => true,
    'moderation_failure_mode' => 'fail_open',
    'trace_input_capture' => !Rails.env.production?,
    'trace_output_capture' => !Rails.env.production?
  }.freeze
  RUNTIME_FEATURE_KEYS = %w[assistant copilot].freeze

  included do
    validate :validate_captain_models

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
  end

  def captain_preferences
    {
      models: captain_models_with_defaults,
      features: captain_features_with_defaults,
      runtime: captain_runtime_with_defaults
    }.with_indifferent_access
  end

  private

  def captain_models_with_defaults
    stored_models = captain_models || {}
    Llm::Models.feature_keys.each_with_object({}) do |feature_key, result|
      stored_value = stored_models[feature_key]
      result[feature_key] = if stored_value.present? && Llm::Models.valid_model_for?(feature_key, stored_value)
                              Llm::Models.canonical_model_name(stored_value)
                            else
                              Llm::Models.default_model_for(feature_key)
                            end
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
    RUNTIME_DEFAULTS.merge(stored_runtime)
  end

  def validate_captain_models
    return if captain_models.blank?

    captain_models.each do |feature_key, model_name|
      next if model_name.blank?
      next if Llm::Models.valid_model_for?(feature_key, model_name)

      allowed_models = Llm::Models.models_for(feature_key)
      errors.add(:captain_models, "'#{model_name}' is not a valid model for #{feature_key}. Allowed: #{allowed_models.join(', ')}")
    end

    captain_models.each do |feature_key, model_name|
      next if model_name.blank?
      next unless Llm::Models.valid_model_for?(feature_key, model_name)
      next if Llm::Models.runtime_supported?(model_name)

      errors.add(:captain_models, "'#{model_name}' for #{feature_key} is not available in RubyLLM.models.")
    end
  end
end
