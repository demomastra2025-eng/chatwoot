# frozen_string_literal: true

# Validates and normalizes the installation configs through which the platform curates the AI models
# (Super Admin -> AI Agents): the model of every platform-managed feature and the short allowlist of
# conversational models. A blank value is always valid and keeps the built-in default.
module Llm::InstallationModelConfig
  ALLOWLIST_CONFIG = Llm::Models::MODEL_ALLOWLIST_INSTALLATION_CONFIG
  ALLOWLIST_LIMIT = 12
  # installation config name => the AI feature it serves
  SLOT_FEATURES = Llm::Config::INSTALLATION_MANAGED_MODEL_CONFIGS.invert.freeze
  Result = Struct.new(:value, :error) do
    def valid? = error.nil?
  end

  class << self
    def manages?(name)
      name == ALLOWLIST_CONFIG || SLOT_FEATURES.key?(name)
    end

    def normalize(name, value)
      name == ALLOWLIST_CONFIG ? normalize_allowlist(value) : normalize_slot(name, value)
    end

    private

    def normalize_slot(name, value)
      model_name = Llm::Models.canonical_model_name(value.to_s.strip)
      return Result.new(model_name) if model_name.blank?
      return Result.new(model_name) if Llm::Models.model_allowed_for_feature?(SLOT_FEATURES[name], model_name)

      Result.new(nil, "модель «#{model_name}» не найдена в каталоге или не подходит для этой функции")
    end

    def normalize_allowlist(value)
      models = parse_allowlist(value)
      return Result.new(nil, 'нужен JSON-список идентификаторов моделей') if models.nil?
      return Result.new('') if models.empty?

      error = allowlist_error(models)
      error ? Result.new(nil, error) : Result.new(JSON.generate(models))
    end

    def allowlist_error(models)
      return "в списке не больше #{ALLOWLIST_LIMIT} моделей" if models.size > ALLOWLIST_LIMIT

      unsuitable = models.reject { |model_name| Llm::Models.model_allowed_for_feature?('assistant', model_name) }
      return "не найдены в каталоге или не подходят агенту: #{unsuitable.join(', ')}" if unsuitable.any?

      default_model = Llm::Config.model_for(feature: 'assistant', fallback: nil)
      return unless default_model.present? && models.exclude?(default_model)

      "в списке должна быть модель агента по умолчанию (#{default_model})"
    end

    # nil when the value is not a JSON array of strings; an empty array for a blank value.
    def parse_allowlist(value)
      parsed = value.is_a?(String) ? parse_json(value) : value
      return [] if parsed.blank?
      return unless parsed.is_a?(Array) && parsed.all?(String)

      parsed.filter_map { |model_name| Llm::Models.canonical_model_name(model_name.strip).presence }.uniq
    end

    def parse_json(text)
      JSON.parse(text.presence || 'null')
    rescue JSON::ParserError
      :invalid
    end
  end
end
