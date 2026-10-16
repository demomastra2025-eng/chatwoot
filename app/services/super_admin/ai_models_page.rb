# frozen_string_literal: true

# The cards of the «Модели ИИ» page (super admin app config `captain`): every setting of CAPTAIN_CONFIG_KEYS with its
# Russian title and description, the value that is in force and where it comes from (set by the platform, or the
# built-in default), grouped by purpose.
#
#   page = SuperAdmin::AiModelsPage.new(
#     keys: SuperAdmin::AppConfigsController::CAPTAIN_CONFIG_KEYS, values: { 'CAPTAIN_DEFAULT_MODEL' => 'openai/gpt-6-luna' },
#     definitions: installation_configs, masked_keys: SuperAdmin::AppConfigsController::MASKED_SECRET_CONFIG_KEYS
#   )
#   page.groups.each do |group|
#     group.slots.each { |slot| slot.key; slot.title; slot.configured; slot.effective }
#   end
#
# A secret never reaches a card: a slot of a masked key carries `configured` and no value, so a view cannot print it.
class SuperAdmin::AiModelsPage
  # editor: :text, :textarea, :allowlist (JSON list of models), :secret, :number or :prompts (the builder of system prompts)
  # value:  what is stored (nil for a masked secret); default: the built-in value (String, Array or nil)
  # default_note: :default_model when the built-in value is "the default model of the installation"
  Slot = Struct.new(:key, :title, :hint, :editor, :value, :configured, :default, :default_note, keyword_init: true) do
    def effective
      configured ? value : default
    end

    def secret?
      editor == :secret
    end

    def wide?
      %i[textarea allowlist prompts].include?(editor)
    end

    # What is in force, as a list of strings to show: the models of a list, or the one value
    def effective_items
      items_of(effective)
    end

    def default_items
      items_of(default)
    end

    private

    def items_of(raw)
      return [] if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)

      editor == :allowlist ? SuperAdmin::AiModelsPage.model_list(raw) : Array(raw).map(&:to_s)
    end
  end
  Group = Struct.new(:key, :title, :hint, :slots, keyword_init: true)

  # The purposes the settings are arranged by, in the order of the page. A key of the page that no group names lands
  # in OTHER_GROUP, so a setting added later is still on the page.
  GROUPS = {
    'agent' => %w[CAPTAIN_DEFAULT_MODEL CAPTAIN_ASSISTANT_MODEL_ALLOWLIST],
    'safety' => %w[CAPTAIN_MODERATION_MODEL CAPTAIN_CUSTOM_GUARDRAIL_MODEL],
    'knowledge' => %w[CAPTAIN_EMBEDDING_MODEL],
    'voice' => %w[CAPTAIN_AUDIO_TRANSCRIPTION_MODEL],
    'images' => %w[CAPTAIN_IMAGE_RECOGNITION_MODEL],
    'classifiers' => %w[
      CAPTAIN_OUTCOME_CLASSIFIER_MODEL CAPTAIN_LANGUAGE_DETECTION_MODEL CAPTAIN_LABEL_SUGGESTION_MODEL CAPTAIN_CUSTOMER_NOTICE_MODEL
    ],
    'prompts' => %w[CAPTAIN_SYSTEM_PROMPTS CAPTAIN_AI_AGENT_SYSTEM_PROMPT CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT],
    'connection' => %w[
      CAPTAIN_OPENROUTER_API_KEY CAPTAIN_OPENROUTER_MANAGEMENT_API_KEY CAPTAIN_OPENROUTER_ENDPOINT CAPTAIN_FIRECRAWL_API_KEY
      ACCOUNT_CAPTAIN_TOKENS_LIMIT
    ]
  }.freeze
  OTHER_GROUP = 'other'
  # Slots whose built-in value is "the default model of the installation" (see Llm::Config#installation_model_for)
  FOLLOWS_DEFAULT_MODEL = %w[CAPTAIN_CUSTOMER_NOTICE_MODEL CAPTAIN_IMAGE_RECOGNITION_MODEL CAPTAIN_LABEL_SUGGESTION_MODEL].freeze
  TEXTAREA_KEYS = %w[CAPTAIN_AI_AGENT_SYSTEM_PROMPT CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT].freeze
  NUMBER_KEYS = %w[ACCOUNT_CAPTAIN_TOKENS_LIMIT].freeze

  # The models of a JSON list (a String or an Array); [] for anything else
  def self.model_list(raw)
    list = raw.is_a?(String) ? JSON.parse(raw.presence || '[]') : raw
    list.is_a?(Array) ? list.map(&:to_s).compact_blank : []
  rescue JSON::ParserError
    []
  end

  # keys: the settings of the page; values: name => stored value; definitions: name => entry of installation_config.yml;
  # masked_keys: the secrets whose value is never shown
  def initialize(keys:, values:, definitions:, masked_keys:)
    @keys = keys.to_a
    @values = values.to_h
    @definitions = definitions.to_h
    @masked_keys = masked_keys.to_a
  end

  def groups
    @groups ||= begin
      placed = GROUPS.values.flatten
      listed = GROUPS.map { |key, names| build_group(key, names & @keys) }
      other = build_group(OTHER_GROUP, @keys - placed)
      (listed + [other]).select { |group| group.slots.any? }
    end
  end

  # The built-in value of a setting: what the platform uses while the slot is blank.
  def default_for(key)
    case key
    when 'CAPTAIN_DEFAULT_MODEL' then Llm::Config::DEFAULT_MODEL
    when Llm::Models::MODEL_ALLOWLIST_INSTALLATION_CONFIG then Llm::Models::DEFAULT_CURATED_MODELS
    when 'CAPTAIN_OPENROUTER_ENDPOINT' then Llm::Config::OPENROUTER_DEFAULT_API_BASE
    else slot_default(key)
    end
  end

  private

  def build_group(key, names)
    Group.new(
      key: key,
      title: I18n.t("super_admin.app_config.captain.groups.#{key}.title"),
      hint: I18n.t("super_admin.app_config.captain.groups.#{key}.hint", default: ''),
      slots: names.map { |name| build_slot(name) }
    )
  end

  def build_slot(key)
    definition = @definitions[key]
    stored = @values[key]
    masked = @masked_keys.include?(key)
    Slot.new(
      key: key,
      title: SuperAdmin::AppConfigLabels.title(key, definition),
      hint: SuperAdmin::AppConfigLabels.hint(key, definition),
      editor: editor_for(key, definition),
      value: masked ? nil : stored,
      configured: stored.present?,
      default: default_for(key),
      default_note: FOLLOWS_DEFAULT_MODEL.include?(key) ? :default_model : nil
    )
  end

  def editor_for(key, definition)
    return :prompts if key == Captain::Assistant::GLOBAL_SYSTEM_PROMPTS_INSTALLATION_CONFIG
    return :allowlist if key == Llm::Models::MODEL_ALLOWLIST_INSTALLATION_CONFIG
    return :secret if definition.to_h['type'] == 'secret'
    return :number if NUMBER_KEYS.include?(key)
    return :textarea if TEXTAREA_KEYS.include?(key) || definition.to_h['type'] == 'code'

    :text
  end

  # The model the installation follows for a slot of an AI feature (llm.yml), or the default model for the slots
  # that have no model of their own.
  def slot_default(key)
    feature = Llm::InstallationModelConfig::SLOT_FEATURES[key]
    return if feature.blank?
    return @values['CAPTAIN_DEFAULT_MODEL'].presence || Llm::Config::DEFAULT_MODEL if FOLLOWS_DEFAULT_MODEL.include?(key)

    Llm::Models.configured_default_model_for(feature).presence
  end
end
