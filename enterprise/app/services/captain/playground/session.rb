require 'digest'

class Captain::Playground::Session
  include Captain::Playground::LiveCallerSource
  include Captain::Playground::LiveSession

  MAX_HISTORY = 40
  MAX_MESSAGE_LENGTH = 12_000
  LIVE_WARNING = 'Боевой режим: данные клиента тестовые, действия в выбранной клинике — реальные.'.freeze

  attr_reader :assistant, :account, :user, :mode, :data, :scenario

  def initialize(assistant:, account:, user:, mode: 'trial', session_id: nil)
    @assistant = assistant
    @account = account
    @user = user
    @mode = mode.to_s
    @requested_id = session_id.presence
    @store = Captain::Playground::SessionStore.new(account: account, user: user, assistant: assistant, mode: @mode)
    authorize_live! if live?
  end

  def with_lock(reset: false, scenario_input: nil, inbox_id: nil, delivery_enabled: false, delivery_target: nil)
    @store.with_lock do
      load_data!(reset: reset, scenario_input: scenario_input)
      prepare_live!(inbox_id: inbox_id, delivery_enabled: delivery_enabled, delivery_target: delivery_target) if live?
      begin
        yield self
      ensure
        # Completed synthetic actions must survive a provider timeout later in the same turn.
        save!
      end
    end
  end

  def trial?
    mode == 'trial'
  end

  def live?
    mode == 'live'
  end

  def id
    data.fetch('id')
  end

  def save!
    data['scenario'] = scenario.data
    @store.write(data)
  end

  def context_reference
    { session_id: id, mode: mode, account_id: account.id, user_id: user.id, assistant_id: assistant.id }
  end

  def state
    return scenario.state.merge(playground: context_reference) if trial?

    { playground: context_reference }
  end

  def conversation
    return if trial?

    @conversation ||= account.conversations.find_by!(id: data['conversation_id'], contact_id: data['caller_contact_id'])
  end

  def assert_context!(state)
    reference = state.to_h.with_indifferent_access[:playground].to_h.with_indifferent_access
    expected = context_reference.with_indifferent_access
    unless expected.all? { |key, value| reference[key] == value }
      raise ArgumentError, 'Playground execution context does not match the server session'
    end
    raise ArgumentError, 'Playground source is required' unless state.to_h.with_indifferent_access[:source] == 'playground'

    return if trial?

    assert_live_caller!(state.to_h.with_indifferent_access)
    validate_live_source!
  end

  def run_policy
    return unless live?

    @run_policy ||= Outbound::PlaygroundDeliveryPolicy.issue(
      mode: mode, run_id: SecureRandom.uuid, session_id: id, account_id: account.id, user_id: user.id, assistant_id: assistant.id,
      caller_contact_id: conversation.contact_id, conversation_id: conversation.id, inbox_id: conversation.inbox_id,
      delivery_enabled: data['delivery_enabled'] == true, delivery_target: data['delivery_target']
    )
  end

  def history_with(message)
    text = message.to_s
    raise ArgumentError, 'Message is required' if text.blank?
    raise ArgumentError, 'Message is too long' if text.length > MAX_MESSAGE_LENGTH

    Array(data['history']).last(MAX_HISTORY) + [{ role: 'user', content: text }]
  end

  def record_turn(message, response)
    response = response.to_h.deep_stringify_keys
    history = history_with(message)
    history << { role: 'assistant', content: response['response'].to_s.first(MAX_MESSAGE_LENGTH), agent_name: response['agent_name'] }.compact
    data['history'] = history.last(MAX_HISTORY)
    data['history'].shift(2) while JSON.generate(data['history']).bytesize > 160_000
  end

  def payload
    {
      session_id: id, mode: mode, scenario: scenario.public_data(mode: mode), message_history: data['history'],
      live_available: administrator?,
      inboxes: accessible_inboxes.map { |inbox| { id: inbox.id, name: inbox.name, channel_type: inbox.channel_type } }
    }.merge(live_payload).compact
  end

  private

  def load_data!(reset:, scenario_input:)
    @data = @store.read(session_id: reset ? nil : @requested_id)
    @data = new_data if reset || @data.nil?
    @scenario = Captain::Playground::Scenario.new(@data['scenario'])
    @scenario.apply(scenario_input, mode: mode) if scenario_input.present?
    @profile_phone_edited = scenario_input.to_h.with_indifferent_access.dig(:contact, :phone_number).present?
  end

  def assert_live_caller!(state)
    return if state.dig(:conversation, :id) == conversation.id && state.dig(:contact, :id) == conversation.contact_id

    raise ArgumentError, 'Playground caller does not match the selected source'
  end

  def new_data
    initial_scenario = if live?
                         Captain::Playground::Scenario.live_default(timezone: account.reporting_timezone)
                       else
                         Captain::Playground::Scenario.default(timezone: account.reporting_timezone)
                       end
    { 'id' => SecureRandom.uuid, 'mode' => mode, 'scenario' => initial_scenario, 'history' => [] }
  end

  def administrator?
    account.account_users.find_by(user_id: user.id)&.administrator? == true
  end

  def authorize_live!
    raise Pundit::NotAuthorizedError, 'Account administrator permission is required for Live Playground' unless administrator?
  end

  def accessible_inboxes
    @accessible_inboxes ||= if administrator?
                             account.inboxes.order(:id).to_a
                           else
                             account.inboxes.where(id: user.assigned_inboxes.select(:id)).order(:id).to_a
                           end
  end

  def selected_inbox(inbox_id)
    id = inbox_id.presence || data['inbox_id']
    accessible_inboxes.find { |inbox| inbox.id.to_s == id.to_s } || raise(ArgumentError, 'Select a workspace inbox for Live Playground')
  end

end
