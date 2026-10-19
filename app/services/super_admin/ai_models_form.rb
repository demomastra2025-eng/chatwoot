# frozen_string_literal: true

# What the «Модели ИИ» page sends when «Сохранить» is pressed, checked as a whole before anything is saved:
#
#   form = SuperAdmin::AiModelsForm.new(submitted: params[:app_config], stored: values, keys: keys, masked_keys: masked)
#   form.valid?   # => false: form.errors is { 'CAPTAIN_DEFAULT_MODEL' => ['Russian text'] }, nothing was written
#   form.save(actor: current_super_admin, request: request) # => {} when everything was saved, else the errors by setting
#
# * All or nothing: one wrong value saves nothing, so the page never half applies what the admin sent.
# * Only what was changed is checked and written. A model that is saved but is not in the catalog any more stays as it
#   is (and does not stop the other settings from being saved); it is replaced only when the admin picks another one.
# * The short list and the default model are checked together, against each other's NEW values, in one save: adding a
#   model and making it the default is one step, and a default that is not on the list can not be built.
# * The model of the knowledge base search is changed only on an explicit confirmation (`confirmed_embedding`): a new model
#   makes the search worse until the bases are indexed again.
# * A secret that is left empty keeps the stored value.
class SuperAdmin::AiModelsForm
  # old/new: the stored value and the value to store (nil for a secret: its value is never shown anywhere)
  Change = Struct.new(:key, :old, :new, :secret, keyword_init: true)

  ALLOWLIST = Llm::InstallationModelConfig::ALLOWLIST_CONFIG
  DEFAULT_MODEL = Llm::InstallationModelConfig::DEFAULT_MODEL_CONFIG
  EMBEDDING_MODEL = 'CAPTAIN_EMBEDDING_MODEL'
  PROMPTS = Captain::Assistant::GLOBAL_SYSTEM_PROMPTS_INSTALLATION_CONFIG
  ENDPOINT = 'CAPTAIN_OPENROUTER_ENDPOINT'
  NUMBER_KEYS = SuperAdmin::AiModelsPage::NUMBER_KEYS
  PROMPT_FIELDS = %i[id type group content slot].freeze
  SCOPE = 'super_admin.app_config.captain.form'

  attr_reader :errors, :changes, :input

  # submitted: name => what was sent (a String, or an Array for the short list); stored: name => the stored value
  def initialize(submitted:, stored:, keys:, masked_keys:, confirmed_embedding: false)
    @keys = keys.to_a
    @masked = masked_keys.to_a
    @stored = stored.to_h
    @submitted = submitted.to_h.slice(*@keys)
    @confirmed_embedding = confirmed_embedding
    @errors = {}
    @changes = []
    @input = {}
    check
  end

  def valid?
    @errors.empty?
  end

  # Writes every change, or none when one of them is refused (the record of a setting can still say no). Returns the errors by setting.
  def save(actor:, request: nil)
    return @errors unless valid?

    saver = SuperAdmin::AppConfigSaver.new(actor: actor, request: request)
    ActiveRecord::Base.transaction do
      @changes.each do |change|
        messages = saver.save(change.key, change.new, secret: change.secret)
        add_error(change.key, messages.join('; ')) if messages.any?
      end
      raise ActiveRecord::Rollback if @errors.any?
    end
    @errors
  end

  # One line per change, for the message after a save: «Проверка безопасности ответов: GPT-5.4 → встроенная»
  def summary
    @changes.map { |change| describe(change) }
  end

  private

  def check
    @submitted.each do |key, value|
      @input[key] = value unless @masked.include?(key)
      next check_secret(key, value) if @masked.include?(key)
      next if [ALLOWLIST, DEFAULT_MODEL].include?(key)

      check_value(key, value)
    end
    check_models_together
  end

  def check_secret(key, value)
    return if value.blank?

    @changes << Change.new(key: key, old: nil, new: value, secret: true)
  end

  def check_value(key, value)
    return check_prompts(value) if key == PROMPTS
    return check_model(key, value) if Llm::InstallationModelConfig.manages?(key)
    return check_number(key, value) if NUMBER_KEYS.include?(key)
    return check_endpoint(key, value) if key == ENDPOINT

    change(key, value) unless value.to_s == @stored[key].to_s
  end

  # --- a model of one function ---------------------------------------------------------------------------------------

  def check_model(key, value)
    wanted = Llm::Models.canonical_model_name(value.to_s.strip)
    return if wanted == Llm::Models.canonical_model_name(@stored[key].to_s.strip)

    result = Llm::InstallationModelConfig.normalize(key, value)
    return add_error(key, result.error) unless result.valid?
    return add_error(key, I18n.t("#{SCOPE}.embedding_unconfirmed")) if key == EMBEDDING_MODEL && !embedding_confirmed?(result.value)

    change(key, result.value)
  end

  # The search of the knowledge base follows the model that is in force: a change of it needs the confirmation
  def embedding_confirmed?(new_value)
    return true if @confirmed_embedding

    builtin = Llm::Models.configured_default_model_for('help_center_search')
    (@stored[EMBEDDING_MODEL].presence || builtin) == (new_value.presence || builtin)
  end

  # --- the short list and the default model, together -----------------------------------------------------------------

  def check_models_together
    return unless @submitted.key?(ALLOWLIST) || @submitted.key?(DEFAULT_MODEL)

    list = effective_list
    default = effective_default
    check_default(list) if @submitted.key?(DEFAULT_MODEL)
    check_list(default) if @submitted.key?(ALLOWLIST) && list
  end

  # The models of the short list after the save: nil when what was sent is not a list
  def effective_list
    return stored_list unless @submitted.key?(ALLOWLIST)

    @submitted_list = Llm::InstallationModelConfig.parse_models(@submitted[ALLOWLIST])
    return @submitted_list if @submitted_list

    add_error(ALLOWLIST, I18n.t("#{SCOPE}.list_invalid"))
    nil
  end

  def stored_list
    Llm::InstallationModelConfig.parse_models(@stored[ALLOWLIST]) || []
  end

  # The model of the agent after the save: the one sent, else the stored one, else the built-in one
  def effective_default
    raw = @submitted.key?(DEFAULT_MODEL) ? @submitted[DEFAULT_MODEL] : @stored[DEFAULT_MODEL]
    Llm::Models.canonical_model_name(raw.to_s.strip).presence || Llm::Models.default_model_for('assistant').presence || Llm::Config::DEFAULT_MODEL
  end

  def check_default(list)
    wanted = Llm::Models.canonical_model_name(@submitted[DEFAULT_MODEL].to_s.strip)
    return if wanted == Llm::Models.canonical_model_name(@stored[DEFAULT_MODEL].to_s.strip)

    result = Llm::InstallationModelConfig.normalize(DEFAULT_MODEL, wanted, allowlist: list.presence)
    result.valid? ? change(DEFAULT_MODEL, result.value) : add_error(DEFAULT_MODEL, result.error)
  end

  def check_list(default)
    return if unchanged_list?

    # what is in force stays valid: the stored models, or the recommended list while none is stored
    trusted = stored_list.presence || Llm::Models::DEFAULT_CURATED_MODELS
    result = Llm::InstallationModelConfig.normalize(ALLOWLIST, @submitted_list, default_model: default, trusted: trusted)
    return add_error(ALLOWLIST, result.error) unless result.valid?

    # the models the platform recommends are the list that is in force while none is stored: put back as «follow the recommended list»
    value = @submitted_list.sort == Llm::Models::DEFAULT_CURATED_MODELS.sort ? '' : result.value
    change(ALLOWLIST, value)
  end

  # The same models as before (the order of the checkboxes is not a choice), or the recommended list while none is stored
  def unchanged_list?
    stored = stored_list
    return @submitted_list.sort == Llm::Models::DEFAULT_CURATED_MODELS.sort if stored.empty? && @submitted_list.any?

    @submitted_list.sort == stored.sort
  end

  # --- numbers, addresses, system prompts -----------------------------------------------------------------------------

  def check_number(key, value)
    digits = value.to_s.gsub(/[\s_]/, '')
    return add_error(key, I18n.t("#{SCOPE}.number_invalid")) unless digits.match?(/\A\d*\z/)

    change(key, digits) unless digits == @stored[key].to_s
  end

  def check_endpoint(key, value)
    text = value.to_s.strip
    return add_error(key, I18n.t("#{SCOPE}.endpoint_invalid")) unless text.empty? || text.match?(%r{\Ahttps?://\S+\z})

    change(key, text) unless text == @stored[key].to_s
  end

  def check_prompts(value)
    entries = parse_prompts(value)
    return add_error(PROMPTS, I18n.t("#{SCOPE}.prompts_invalid")) if entries.nil?

    problem = prompts_problem(entries)
    return add_error(PROMPTS, problem) if problem

    change(PROMPTS, entries) unless entries == prompts_of(@stored[PROMPTS])
  end

  def parse_prompts(value)
    parsed = value.present? ? JSON.parse(value) : []
    return unless parsed.is_a?(Array)

    prompts_of(parsed)
  rescue JSON::ParserError
    nil
  end

  # The rules as they are stored: only the five fields
  def prompts_of(raw)
    Captain::Assistant.normalize_installation_system_prompt_entries(raw.is_a?(Array) ? raw : []).map do |entry|
      PROMPT_FIELDS.to_h { |field| [field.to_s, entry[field]] }
    end
  end

  # A group or a place that is not in the lists is allowed only for a rule that already has it (an old value is not lost)
  def prompts_problem(entries)
    stored = prompts_of(@stored[PROMPTS]).index_by { |entry| entry['id'] }
    entries.each_with_index do |entry, index|
      before = stored[entry['id']].to_h
      unless SuperAdmin::SystemPromptOptions.group_values.include?(entry['group']) || entry['group'] == before['group']
        return I18n.t("#{SCOPE}.group_unknown", number: index + 1, group: entry['group'])
      end
      next if entry['slot'].blank? || SuperAdmin::SystemPromptOptions.slot_values.include?(entry['slot']) || entry['slot'] == before['slot']

      return I18n.t("#{SCOPE}.slot_unknown", number: index + 1, slot: entry['slot'])
    end
    nil
  end

  # --- bookkeeping ---------------------------------------------------------------------------------------------------

  def change(key, value)
    @changes << Change.new(key: key, old: @stored[key], new: value, secret: false)
  end

  def add_error(key, message)
    (@errors[key] ||= []) << message
  end

  def describe(change)
    title = SuperAdmin::AppConfigLabels.title(change.key, SuperAdmin::InstallationConfigs.definitions[change.key])
    return I18n.t("#{SCOPE}.changed.secret", title: title) if change.secret

    detail = case change.key
             when ALLOWLIST then list_change(change)
             when PROMPTS then I18n.t("#{SCOPE}.changed.prompts")
             else single_change(change)
             end
    "#{title}: #{detail}"
  end

  def single_change(change)
    return "#{value_text(change.old, change.key)} → #{value_text(change.new, change.key)}" if model_key?(change.key)

    change.new.to_s.presence ? I18n.t("#{SCOPE}.changed.value") : I18n.t("#{SCOPE}.changed.cleared")
  end

  def list_change(change)
    before = Llm::InstallationModelConfig.parse_models(change.old).to_a.size
    after = Llm::InstallationModelConfig.parse_models(change.new).to_a.size
    I18n.t("#{SCOPE}.changed.list", before: before, after: after)
  end

  def model_key?(key)
    SuperAdmin::AiModelsPage::MODEL_KEYS.include?(key)
  end

  def value_text(model_id, _key)
    SuperAdmin::AiModelOptions.name_of(model_id) || I18n.t("#{SCOPE}.changed.builtin")
  end
end
