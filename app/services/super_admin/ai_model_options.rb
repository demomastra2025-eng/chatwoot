# frozen_string_literal: true

# The models a setting of the «Модели ИИ» page can be set to, ready for a list: for every setting the models that fit its
# function (the same ones the platform accepts when the setting is saved), each with a readable name, the price for one
# million tokens and what it can do, the recommended ones first and the rest grouped by the company that makes them.
#
#   options = SuperAdmin::AiModelOptions.new
#   choices = options.choices_for('CAPTAIN_AUDIO_TRANSCRIPTION_MODEL', current: 'vendor/gone', builtin: 'openai/gpt-4o-mini-transcribe')
#   choices.builtin_name   # => "GPT-4o Mini Transcribe"
#   choices.missing        # => the saved model that is not on the list: it stays selected, with its own mark
#   choices.groups         # => [[«Рекомендуемые», [Option, ...]], [«OpenAI», [Option, ...]], ...]
#
# Nothing here changes a setting. The list works without a loaded OpenRouter catalog (the built-in list of the
# platform is used then) and never drops a saved model: a model the list does not offer is still returned as `missing`.
class SuperAdmin::AiModelOptions
  # price_in / price_out: US dollars for one million tokens (BigDecimal), nil when the catalog has no price.
  # badges: what the model can do, in Russian («картинки», «инструменты», «рассуждение»).
  # note: the mark of a saved model the list does not offer («нет в каталоге», «сейчас не подходит для этой функции»);
  # reason: why it is not offered, :not_in_catalog or :not_fit (nil for a model the list offers).
  Option = Struct.new(:id, :name, :provider, :price_in, :price_out, :badges, :recommended, :note, :reason, keyword_init: true) do
    def missing?
      note.present?
    end

    # «вход $0,15 / выход $0,60 за 1 млн» or «бесплатно»; nil when the catalog has no price (nothing is written then)
    def price_text
      SuperAdmin::AiModelOptions.price_text(price_in, price_out)
    end

    # The whole option as plain text, for a list without a script
    def label
      [name, price_text, badges.join(', ').presence, note].compact_blank.join(' · ')
    end
  end

  Choices = Struct.new(:builtin_name, :builtin_id, :groups, :missing, keyword_init: true) do
    def size
      groups.sum { |_title, options| options.size }
    end

    def ids
      groups.flat_map { |_title, options| options.map(&:id) }
    end

    def include?(model_id)
      ids.include?(model_id)
    end
  end

  # The functions (see config/llm.yml) a setting has to fit: a model must fit every one of them.
  SLOT_FEATURES = Llm::InstallationModelConfig::SLOT_FEATURES.transform_values { |feature| [feature] }.merge(
    Llm::InstallationModelConfig::DEFAULT_MODEL_CONFIG => Llm::InstallationModelConfig::DEFAULT_MODEL_FEATURES,
    Llm::InstallationModelConfig::ALLOWLIST_CONFIG => %w[assistant]
  ).freeze
  PROVIDER_TITLES = {
    'openai' => 'OpenAI', 'anthropic' => 'Anthropic', 'google' => 'Google', 'meta-llama' => 'Meta', 'mistralai' => 'Mistral',
    'x-ai' => 'xAI', 'deepseek' => 'DeepSeek', 'qwen' => 'Qwen', 'inception' => 'Inception', 'microsoft' => 'Microsoft',
    'amazon' => 'Amazon', 'cohere' => 'Cohere', 'nvidia' => 'NVIDIA', 'moonshotai' => 'Moonshot', 'z-ai' => 'Z.ai', 'perplexity' => 'Perplexity'
  }.freeze
  CAPABILITY_BADGES = [
    [%w[image_input multimodal_input], 'картинки'], [%w[tool_calling], 'инструменты'], [%w[reasoning], 'рассуждение']
  ].freeze
  OTHER_PROVIDER = 'Прочие'
  PRICE_UNIT_TOKENS = 1_000_000

  class << self
    # "вход $0,15 / выход $0,60 за 1 млн"; nil for a model without a price
    def price_text(price_in, price_out)
      scope = 'super_admin.app_config.captain.models'
      return if price_in.nil? && price_out.nil?
      return I18n.t("#{scope}.free") if price_in.to_d.zero? && price_out.to_d.zero?
      # an embedding model is paid for what it reads only
      return I18n.t("#{scope}.price_one", price: dollars(price_in || price_out)) if reads_only?(price_in, price_out)

      I18n.t("#{scope}.price_both", price_in: dollars(price_in), price_out: dollars(price_out))
    end

    # "$0,15", "$10", "$0,075"
    def dollars(amount)
      return if amount.nil?

      number = ActiveSupport::NumberHelper.number_to_rounded(
        amount, precision: amount < 0.1 ? 3 : 2, separator: ',', delimiter: ' ', strip_insignificant_zeros: true
      )
      "$#{number}"
    end

    def reads_only?(price_in, price_out)
      price_in.nil? || price_out.nil? || price_out.zero?
    end

    # The readable name of a model id: the name of the catalog, or the id itself when the platform does not know the model
    def name_of(model_id)
      model_id = Llm::Models.canonical_model_name(model_id)
      return if model_id.blank?

      Llm::Models.model_config(model_id).to_h['display_name'].presence || model_id
    rescue StandardError
      model_id
    end

    # The company of a model id (the part before «/»)
    def provider_title(model_id)
      prefix = model_id.to_s.include?('/') ? model_id.to_s.split('/', 2).first : nil
      return OTHER_PROVIDER if prefix.blank?

      PROVIDER_TITLES.fetch(prefix) { prefix.tr('-_', '  ').split.map(&:capitalize).join(' ') }
    end
  end

  # recommended: the ids shown first (the short list of the platform, the built-in models)
  def initialize(recommended: [])
    @recommended = Array(recommended).filter_map { |model_id| Llm::Models.canonical_model_name(model_id).presence }.uniq
    @candidates = {}
  end

  # builtin: the model the platform uses while the setting is blank; current: the value that is saved ('' for none)
  def choices_for(key, current: nil, builtin: nil)
    with_snapshots do
      features = SLOT_FEATURES[key]
      ids = features ? candidates(features) : []
      current = Llm::Models.canonical_model_name(current.to_s.strip).presence
      missing = missing_option(current, ids)
      grouped = group_options(ids.map { |model_id| option_for(model_id) })
      Choices.new(builtin_name: self.class.name_of(builtin), builtin_id: builtin.presence, groups: grouped, missing: missing)
    end
  end

  # One model as an option of the list of a setting: with the mark «нет в каталоге» or «не подходит» when the list does not offer it
  def describe(model_id, key:)
    with_snapshots do
      model_id = Llm::Models.canonical_model_name(model_id)
      offered = candidates(SLOT_FEATURES.fetch(key, []))
      option_for(model_id, unavailable: !offered.include?(model_id))
    end
  end

  # Every model that fits all the functions of a setting, in the order of the catalog
  def candidates(features)
    @candidates[features] ||= features.map { |feature| models_for(feature) }.reduce(:&).to_a
  end

  private

  def models_for(feature)
    with_snapshots do
      Llm::Models.models_for(feature).map { |model_id| Llm::Models.canonical_model_name(model_id) }.select { |model_id| openrouter?(model_id) }.uniq
    end
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin::AiModelOptions] The models of #{feature} could not be listed: #{e.class}: #{e.message}")
    []
  end

  # One catalog read for the whole list instead of one per model (it nests: inside a snapshot it is the same snapshot)
  def with_snapshots(&)
    Llm::OpenRouterModelCatalog.with_model_configs_snapshot do
      Llm::OpenRouterEndpointCatalog.with_endpoint_configs_snapshot do
        Llm::Config.with_runtime_cache(&)
      end
    end
  end

  def openrouter?(model_id)
    Llm::ProviderVisibilityPolicy.normal_captain_provider?(Llm::Models.provider_for(model_id))
  end

  # unavailable: the list does not offer the model (it is saved, so it is returned with a mark and the reason)
  def option_for(model_id, unavailable: false)
    config = Llm::Models.model_config(model_id).to_h
    reason = (config.present? ? :not_fit : :not_in_catalog) if unavailable
    Option.new(
      id: model_id, name: config['display_name'].presence || model_id, provider: self.class.provider_title(model_id),
      price_in: price_per_million(config.dig('pricing', 'prompt')), price_out: price_per_million(config.dig('pricing', 'completion')),
      badges: badges_for(config), recommended: @recommended.include?(model_id),
      note: (I18n.t("super_admin.app_config.captain.models.#{reason}") if reason), reason: reason
    )
  end

  # The saved model, when the list does not offer it: not in the catalog any more, or not fit for this function
  def missing_option(current, offered)
    return if current.blank? || offered.include?(current)

    option_for(current, unavailable: true)
  end

  # [[«Рекомендуемые», [...]], [«OpenAI», [...]], ...]
  def group_options(options)
    recommended, others = options.partition(&:recommended)
    groups = by_provider(others)
    return groups if recommended.empty?

    [[I18n.t('super_admin.app_config.captain.models.recommended'), recommended.sort_by { |option| @recommended.index(option.id) }]] + groups
  end

  # The companies in alphabetical order, «Прочие» last, the models of each by name
  def by_provider(options)
    options.group_by(&:provider)
           .sort_by { |provider, _options| [provider == OTHER_PROVIDER ? 1 : 0, provider.downcase] }
           .map { |provider, list| [provider, list.sort_by { |option| option.name.downcase }] }
  end

  def badges_for(config)
    capabilities = Array(config['capabilities']).map { |name| Llm::Models::CAPABILITY_ALIASES.fetch(name.to_s, name.to_s) }
    CAPABILITY_BADGES.filter_map { |names, badge| badge if names.intersect?(capabilities) }
  end

  # The catalog keeps the price of one token (a text of a number); nil when it has none or the price is not a number
  def price_per_million(value)
    return if value.blank?

    price = BigDecimal(value.to_s)
    price.negative? ? nil : price * PRICE_UNIT_TOKENS
  rescue ArgumentError, TypeError
    nil
  end
end
