# frozen_string_literal: true

# What the AI of one account looks like for the card of the account (the block «ИИ»): the model its agents really answer
# with (the platform's own or one the account chose), how many AI agents it has and how many are switched on, whether the
# account may bring its own OpenRouter key and whether it has connected one. Nothing is written, and a problem of the AI
# settings of the platform never breaks the card: the model is then shown as unknown.
#
#   state = SuperAdmin::AccountAiState.new(account)
#   state.model_name        # => "GPT-6 Luna" (nil when no model can be chosen at all)
#   state.own_model?        # => false: the platform's model; true: the account chose its own
#   state.agents_total      # => 3
#   state.agents_enabled    # => 2
#   state.own_key_allowed?  # => the flag «Разрешить свой ключ OpenRouter» of the account
#   state.own_key_connected? # => the account has connected a key (it is used only while the flag is on)
class SuperAdmin::AccountAiState
  FEATURE = 'assistant'
  OPENROUTER = 'openrouter'

  def initialize(account)
    @account = account
  end

  # Whether the plan of the account gives it AI agents at all
  def module_enabled?
    @account.feature_enabled?('captain_integration')
  end

  # The model the agents of the account answer with
  def model_id
    return @model_id if defined?(@model_id)

    @model_id = Llm::Config.model_for(feature: FEATURE, account: @account).presence
  rescue StandardError => e
    log('model', e)
    @model_id = nil
  end

  # The model of the platform, the one an account without a choice of its own gets
  def platform_model_id
    return @platform_model_id if defined?(@platform_model_id)

    @platform_model_id = Llm::Config.model_for(feature: FEATURE).presence
  rescue StandardError => e
    log('platform model', e)
    @platform_model_id = nil
  end

  def model_name
    SuperAdmin::AiModelOptions.name_of(model_id)
  end

  # The account chose a model of its own and it is the one in use (a choice that has become unusable falls back to the platform's)
  def own_model?
    chosen = @account.captain_models.to_h[FEATURE].presence
    chosen.present? && model_id.present? && model_id != platform_model_id
  end

  def agents_total
    agents.count
  end

  def agents_enabled
    agents.where(active: true).count
  end

  # Agents that keep a model of their own, whatever the account's setting says
  def agents_with_own_model
    agents.where("COALESCE(config ->> 'model', '') <> ''").count
  end

  def own_key_allowed?
    @account.feature_enabled?('captain_openrouter_byok')
  end

  # An OpenRouter key saved by the account (the hook of its settings page)
  def own_key_connected?
    hook = @account.hooks.find_by(app_id: OPENROUTER, status: 'enabled')
    return false if hook.nil?

    hook.access_token.present? || hook.settings.to_h.with_indifferent_access[:api_key].present?
  end

  private

  # The AI agents that answer clients (the internal assistants of the operators are not offered anywhere)
  def agents
    Captain::Assistant.where(account_id: @account.id, usage_mode: 'external_agent')
  end

  def log(what, error)
    Rails.logger.warn("[SuperAdmin::AccountAiState] The #{what} of account #{@account.id} could not be read: #{error.class.name}: #{error.message}")
  end
end
