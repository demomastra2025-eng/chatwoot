require 'digest'

class Captain::Playground::Session
  MAX_HISTORY = 40
  MAX_MESSAGE_LENGTH = 12_000
  LIVE_WARNING = 'Разрешены изменения реальных данных. Каждое действие требует отдельного подтверждения.'.freeze

  attr_reader :assistant, :account, :user, :data, :scenario, :namespace, :store

  def initialize(assistant:, account:, user:, mode: 'workspace', session_id: nil)
    raise ArgumentError, 'Legacy Live Playground is unavailable; reset the session' if mode.to_s == 'live'

    @assistant, @account, @user = assistant, account, user
    @requested_id = session_id.presence
    @store = Captain::Playground::SessionStore.new(account: account, user: user, assistant: assistant, mode: mode)
  end

  def mode = 'workspace'
  def trial? = true
  def live? = false
  def conversation = nil

  def with_lock(reset: false, scenario_input: nil, **)
    store.with_lock do
      load_data!(reset: reset, scenario_input: scenario_input)
      begin
        yield self
      ensure
        save!
      end
    end
  end

  def id = data.fetch('id')

  def save!
    data['scenario'] = scenario.data
    store.write(data)
  end

  def permissions
    store.permissions(session_id: id)
  end

  def read_enabled? = permissions['read'] == true
  def write_enabled? = read_enabled? && permissions['write'] == true

  def set_permissions!(read:, write:)
    ensure_membership!
    store.set_permissions(session_id: @requested_id || id, read: read, write: write)
  end

  def context_reference
    { session_id: id, mode: mode, account_id: account.id, user_id: user.id, assistant_id: assistant.id }
  end

  def state
    namespace.encode(scenario.state).merge(playground: context_reference, playground_permissions: permissions.slice('read', 'write'))
  end

  def assert_context!(state)
    reference = state.to_h.with_indifferent_access[:playground].to_h.with_indifferent_access
    unless context_reference.all? { |key, value| reference[key] == value }
      raise ArgumentError, 'Playground execution context does not match the server session'
    end
    raise ArgumentError, 'Playground source is required' unless state.to_h.with_indifferent_access[:source] == 'playground'

    ensure_membership!
  end

  def run_policy
    @run_policy ||= Outbound::PlaygroundDeliveryPolicy.issue(
      mode: mode, run_id: SecureRandom.uuid, session_id: id, account_id: account.id,
      user_id: user.id, assistant_id: assistant.id, delivery_enabled: false
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
    current = permissions
    pending = Array(data['action_previews']).select do |preview|
      preview['status'] == 'pending' && current['write'] == true && preview['generation'] == current['generation'] &&
        preview['expires_at'].to_i > Time.current.to_i
    end
    { session_id: id, mode: mode, scenario: namespace.encode(scenario.public_data(mode: mode)),
      message_history: data['history'], real_data_read: current['read'] == true, real_data_write: current['write'] == true,
      delivery_enabled: false, action_previews: pending.map { |preview| preview.except('generation') },
      expires_in: Captain::Playground::SessionStore::TTL }
  end

  private

  def load_data!(reset:, scenario_input:)
    @data = store.read(session_id: reset ? nil : @requested_id)
    fresh = reset || @data.nil?
    @data = new_data if fresh
    @namespace = Captain::Playground::SyntheticNamespace.new(id)
    @scenario = Captain::Playground::Scenario.new(data['scenario'])
    scenario.apply(namespace.decode(scenario_input), mode: mode) if scenario_input.present?
    if scenario_input.present?
      Array(data['action_previews']).each { |preview| preview['status'] = 'revoked' if preview['status'] == 'pending' }
    end
    if fresh
      save!
      store.set_permissions(session_id: id, read: false, write: false)
    end
  end

  def new_data
    configuration = account.crm_field_definitions.active.ordered.map do |definition|
      definition.attributes.slice('entity_kind', 'key', 'label', 'field_type', 'required', 'default_value', 'description', 'options', 'rules', 'active', 'position')
    end
    { 'id' => SecureRandom.uuid, 'version' => 2, 'mode' => mode,
      'scenario' => Captain::Playground::Scenario.default(timezone: account.reporting_timezone).merge('custom_fields' => configuration),
      'history' => [], 'action_previews' => [] }
  end

  def ensure_membership!
    raise Pundit::NotAuthorizedError, 'Workspace membership is required' unless account.account_users.exists?(user_id: user.id)
    raise Pundit::NotAuthorizedError, 'Assistant belongs to another workspace' unless assistant.account_id == account.id
  end
end
