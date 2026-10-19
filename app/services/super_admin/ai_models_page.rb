# frozen_string_literal: true

# The cards of the «Модели ИИ» page (super admin app config `captain`): every setting of CAPTAIN_CONFIG_KEYS with its
# Russian title and description, the value that is in force and where it comes from (set by the platform, or the
# built-in default), grouped by purpose, and the groups arranged in the tabs of the page.
#
#   page = SuperAdmin::AiModelsPage.new(
#     keys: SuperAdmin::AppConfigsController::CAPTAIN_CONFIG_KEYS, values: { 'CAPTAIN_DEFAULT_MODEL' => 'openai/gpt-6-luna' },
#     definitions: installation_configs, masked_keys: SuperAdmin::AppConfigsController::MASKED_SECRET_CONFIG_KEYS
#   )
#   page.tabs.each { |tab| page.groups_of(tab).each { |group| group.slots.each { |slot| slot.key; slot.title; slot.effective } } }
#
# A secret never reaches a card: a slot of a masked key carries `configured` and no value, so a view cannot print it.
#
# A page built with `options:` (SuperAdmin::AiModelOptions) gives every model setting its `choices` (the models to pick
# from); `history:` (SuperAdmin::AiModelsHistory) its `previous` (what it was before the last change); `submitted:` and
# `errors:` are what the platform admin has just sent and what was wrong with it, so the card shows his value and the error.
class SuperAdmin::AiModelsPage
  # editor: :model (one model of a list), :allowlist (the models of the short list), :text, :textarea, :secret, :number
  #         or :prompts (the builder of system prompts)
  # value:  what is stored (nil for a masked secret); default: the built-in value (String, Array or nil)
  # input:  what the control shows: what has just been sent when it was not saved, else what is stored
  # default_note: :default_model when the built-in value is "the default model of the installation"
  # choices: the models of a list (SuperAdmin::AiModelOptions::Choices); previous: SuperAdmin::AiModelsHistory::Entry
  # errors: the messages of what was sent for this setting and not saved
  Slot = Struct.new(:key, :title, :hint, :editor, :value, :configured, :default, :default_note, :input, :choices, :previous, :errors,
                    keyword_init: true) do
    def effective
      configured ? value : default
    end

    def secret?
      editor == :secret
    end

    def model?
      editor == :model
    end

    def wide?
      %i[textarea allowlist prompts].include?(editor)
    end

    def invalid?
      errors.present?
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
  Group = Struct.new(:key, :title, :hint, :slots, :tab, keyword_init: true)

  # The purposes the settings are arranged by, in the order of the page. A key of the page that no group names lands
  # in OTHER_GROUP, so a setting added later is still on the page.
  GROUPS = {
    'connection' => %w[CAPTAIN_OPENROUTER_API_KEY CAPTAIN_OPENROUTER_MANAGEMENT_API_KEY CAPTAIN_FIRECRAWL_API_KEY ACCOUNT_CAPTAIN_TOKENS_LIMIT],
    'agent' => %w[CAPTAIN_DEFAULT_MODEL CAPTAIN_ASSISTANT_MODEL_ALLOWLIST],
    'safety' => %w[CAPTAIN_MODERATION_MODEL CAPTAIN_CUSTOM_GUARDRAIL_MODEL],
    'voice' => %w[CAPTAIN_AUDIO_TRANSCRIPTION_MODEL],
    'images' => %w[CAPTAIN_IMAGE_RECOGNITION_MODEL],
    'classifiers' => %w[
      CAPTAIN_OUTCOME_CLASSIFIER_MODEL CAPTAIN_LANGUAGE_DETECTION_MODEL CAPTAIN_LABEL_SUGGESTION_MODEL CAPTAIN_CUSTOMER_NOTICE_MODEL
    ],
    # the installation prompts are a long list
    'prompts' => %w[CAPTAIN_SYSTEM_PROMPTS CAPTAIN_AI_AGENT_SYSTEM_PROMPT],
    # what only a developer changes: it is folded away at the bottom of the page
    'developer' => %w[CAPTAIN_OPENROUTER_ENDPOINT CAPTAIN_EMBEDDING_MODEL CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT]
  }.freeze
  # The tabs of the page and the groups each shows; the group `developer` is under the tabs, always folded
  TABS = {
    'connection' => %w[connection],
    'models' => %w[agent safety voice images classifiers],
    'prompts' => %w[prompts]
  }.freeze
  DEVELOPER_GROUP = 'developer'
  OTHER_GROUP = 'other'
  # Slots whose built-in value is "the default model of the installation" (see Llm::Config#installation_model_for)
  FOLLOWS_DEFAULT_MODEL = %w[CAPTAIN_CUSTOMER_NOTICE_MODEL CAPTAIN_IMAGE_RECOGNITION_MODEL CAPTAIN_LABEL_SUGGESTION_MODEL].freeze
  TEXTAREA_KEYS = %w[CAPTAIN_AI_AGENT_SYSTEM_PROMPT CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT].freeze
  NUMBER_KEYS = %w[ACCOUNT_CAPTAIN_TOKENS_LIMIT].freeze
  # The settings whose value is one model chosen from a list (the short list is a list of models of its own)
  MODEL_KEYS = (Llm::InstallationModelConfig::SLOT_FEATURES.keys + [Llm::InstallationModelConfig::DEFAULT_MODEL_CONFIG]).freeze

  # The models of a JSON list (a String or an Array); [] for anything else
  def self.model_list(raw)
    list = raw.is_a?(String) ? JSON.parse(raw.presence || '[]') : raw
    list.is_a?(Array) ? list.map(&:to_s).compact_blank : []
  rescue JSON::ParserError
    []
  end

  # keys: the settings of the page; values: name => stored value; definitions: name => entry of installation_config.yml;
  # masked_keys: the secrets whose value is never shown; submitted: name => what the admin has sent and what was not saved
  # errors: name => messages; options: SuperAdmin::AiModelOptions (the lists of models); history: SuperAdmin::AiModelsHistory
  def initialize(keys:, values:, definitions:, masked_keys:, submitted: {}, errors: {}, options: nil, history: nil) # rubocop:disable Metrics/ParameterLists
    @keys = keys.to_a
    @values = values.to_h
    @definitions = definitions.to_h
    @masked_keys = masked_keys.to_a
    @submitted = submitted.to_h
    @errors = errors.to_h
    @options = options
    @history = history
  end

  # The lists of models (SuperAdmin::AiModelOptions) the page was built with, or nil
  attr_reader :options

  def groups
    @groups ||= begin
      placed = GROUPS.values.flatten
      listed = GROUPS.map { |key, names| build_group(key, names & @keys) }
      other = build_group(OTHER_GROUP, @keys - placed)
      (listed + [other]).select { |group| group.slots.any? }
    end
  end

  # The tabs of the page that have something to show: connection, models, prompts
  def tabs
    TABS.keys.select { |tab| groups_of(tab).any? }
  end

  def groups_of(tab)
    groups.select { |group| group.tab == tab }
  end

  # The settings only a developer changes (folded away at the bottom), and those no group names
  def developer_groups
    groups.select { |group| group.key == DEVELOPER_GROUP }
  end

  def other_groups
    groups.select { |group| group.key == OTHER_GROUP }
  end

  def slot(key)
    groups.flat_map(&:slots).find { |candidate| candidate.key == key }
  end

  # Does any setting have something that was not saved (an error)?
  def errors?
    @errors.values.flatten.any?
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
      slots: names.map { |name| build_slot(name) },
      tab: TABS.find { |_tab, group_keys| group_keys.include?(key) }&.first
    )
  end

  def build_slot(key)
    definition = @definitions[key]
    stored = @values[key]
    masked = @masked_keys.include?(key)
    editor = editor_for(key, definition)
    builtin = default_for(key)
    Slot.new(
      key: key,
      title: SuperAdmin::AppConfigLabels.title(key, definition),
      hint: SuperAdmin::AppConfigLabels.hint(key, definition),
      editor: editor,
      value: masked ? nil : stored,
      configured: stored.present?,
      default: builtin,
      default_note: FOLLOWS_DEFAULT_MODEL.include?(key) ? :default_model : nil,
      input: masked ? nil : @submitted.fetch(key, stored),
      choices: choices_for(key, editor, stored, builtin),
      previous: @history&.previous(key),
      errors: Array(@errors[key])
    )
  end

  # The models to pick from: for a setting of one model, and for the short list (to add one more model to it)
  def choices_for(key, editor, stored, builtin)
    return unless @options
    return @options.choices_for(key, current: stored, builtin: builtin) if editor == :model

    @options.choices_for(key) if editor == :allowlist
  end

  def editor_for(key, definition)
    return :prompts if key == Captain::Assistant::GLOBAL_SYSTEM_PROMPTS_INSTALLATION_CONFIG
    return :allowlist if key == Llm::Models::MODEL_ALLOWLIST_INSTALLATION_CONFIG
    return :secret if definition.to_h['type'] == 'secret'
    return :model if MODEL_KEYS.include?(key)
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
