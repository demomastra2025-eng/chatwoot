# frozen_string_literal: true

# Validates and normalizes the installation configs through which the platform curates the AI models
# (Super Admin -> AI Agents): the model of every platform-managed feature and the short allowlist of
# conversational models, and the one default model that the agent, the editor and the copilot follow. A blank value
# is always valid and keeps the built-in default.
module Llm::InstallationModelConfig
  ALLOWLIST_CONFIG = Llm::Models::MODEL_ALLOWLIST_INSTALLATION_CONFIG
  ALLOWLIST_LIMIT = 12
  # The installation-wide default of the features that have no platform-managed slot: an account without a choice of
  # its own follows it, so changing it moves all of them at once (and back: it is the quick rollback of a cut-over).
  DEFAULT_MODEL_CONFIG = 'CAPTAIN_DEFAULT_MODEL'
  DEFAULT_MODEL_FEATURES = %w[assistant editor copilot].freeze
  # installation config name => the AI feature it serves
  SLOT_FEATURES = Llm::Config::INSTALLATION_MANAGED_MODEL_CONFIGS.invert.freeze
  # How the features read in a message to the platform admin
  FEATURE_TITLES = {
    'assistant' => 'основного агента', 'editor' => 'редактора текста', 'copilot' => 'помощника оператора'
  }.freeze
  # «nothing given»: read the value from the settings that are stored (the call of a single setting). A form that saves
  # several settings at once passes the values it is about to save instead, so the rules are checked against the whole.
  NOT_GIVEN = Object.new.freeze
  UNTRUSTED_IMAGE_MODEL_MESSAGE = 'картинки клиентов отдаются только моделям Google, OpenAI и Perplexity: модель «%s» не подходит'
  Result = Struct.new(:value, :error) do
    def valid? = error.nil?
  end

  class << self
    def manages?(name)
      [ALLOWLIST_CONFIG, DEFAULT_MODEL_CONFIG].include?(name) || SLOT_FEATURES.key?(name)
    end

    # allowlist: the short list the default model must be on (an Array, nil for none), default_model: the model of the
    # agent the short list must contain (nil for none), trusted: models of the short list that are already stored (kept
    # even when the catalog has lost them since). All three default to what is stored.
    def normalize(name, value, allowlist: NOT_GIVEN, default_model: NOT_GIVEN, trusted: [])
      return normalize_allowlist(value, default_model: default_model, trusted: trusted) if name == ALLOWLIST_CONFIG
      return normalize_default_model(value, allowlist: allowlist) if name == DEFAULT_MODEL_CONFIG

      normalize_slot(name, value)
    end

    # The models of a short list (a JSON text or an Array) as the list that is stored; nil when it is not a list of ids
    def parse_models(value)
      parse_allowlist(value)
    end

    private

    def normalize_slot(name, value)
      model_name = Llm::Models.canonical_model_name(value.to_s.strip)
      return Result.new(model_name) if model_name.blank?

      feature = SLOT_FEATURES[name]
      unless Llm::Models.model_allowed_for_feature?(feature, model_name)
        return Result.new(nil, "модель «#{model_name}» не найдена в каталоге или не подходит для этой функции")
      end
      return Result.new(nil, UNTRUSTED_IMAGE_MODEL_MESSAGE % model_name) if untrusted_image_model?(feature, model_name)

      Result.new(model_name)
    end

    # A customer's image goes only to the providers the platform trusts with it (Llm::OpenRouterRoutingProfile::TRUSTED_IMAGE_PROVIDERS).
    def untrusted_image_model?(feature, model_name)
      Llm::OpenRouterRoutingProfile::IMAGE_FEATURES.include?(feature) &&
        Llm::OpenRouterRoutingProfile.trusted_image_providers(model_name).blank?
    end

    def normalize_default_model(value, allowlist: NOT_GIVEN)
      model_name = Llm::Models.canonical_model_name(value.to_s.strip)
      return Result.new(model_name) if model_name.blank?

      unsuitable = DEFAULT_MODEL_FEATURES.reject { |feature| Llm::Models.model_allowed_for_feature?(feature, model_name) }
      return Result.new(nil, unsuitable_default_message(model_name, unsuitable)) if unsuitable.any?

      allowlist = Llm::Models.configured_model_allowlist if allowlist.equal?(NOT_GIVEN)
      return Result.new(nil, 'модель по умолчанию должна быть в коротком списке моделей') if allowlist.present? && allowlist.exclude?(model_name)

      Result.new(model_name)
    end

    def unsuitable_default_message(model_name, features)
      titles = features.map { |feature| FEATURE_TITLES.fetch(feature, feature) }
      "модель «#{model_name}» не найдена в каталоге или не подходит для: #{titles.join(', ')}"
    end

    def normalize_allowlist(value, default_model: NOT_GIVEN, trusted: [])
      models = parse_allowlist(value)
      return Result.new(nil, 'нужен JSON-список идентификаторов моделей') if models.nil?
      return Result.new('') if models.empty?

      error = allowlist_error(models, default_model: default_model, trusted: trusted)
      error ? Result.new(nil, error) : Result.new(JSON.generate(models))
    end

    def allowlist_error(models, default_model: NOT_GIVEN, trusted: [])
      return "в списке не больше #{ALLOWLIST_LIMIT} моделей" if models.size > ALLOWLIST_LIMIT

      unsuitable = models.reject { |model_name| trusted.include?(model_name) || Llm::Models.model_allowed_for_feature?('assistant', model_name) }
      return "не найдены в каталоге или не подходят агенту: #{unsuitable.join(', ')}" if unsuitable.any?

      default_missing_error(models, default_model.equal?(NOT_GIVEN) ? Llm::Config.model_for(feature: 'assistant', fallback: nil) : default_model)
    end

    def default_missing_error(models, default_model)
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
