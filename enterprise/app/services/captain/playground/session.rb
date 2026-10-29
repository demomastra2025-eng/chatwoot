require 'digest'

class Captain::Playground::Session
  MAX_HISTORY = 40
  MAX_MESSAGE_LENGTH = 12_000
  LIVE_WARNING = 'Разрешены изменения реальных данных. Каждое действие требует отдельного подтверждения.'.freeze

  # assistant: the agent that answers now (the router picks it each turn; nil before the first one). The Playground tries out the whole
  # AI of the workspace, or of the channel the user picked: it has no start agent.
  attr_reader :assistant, :account, :user, :data, :scenario, :namespace, :store

  def initialize(account:, user:, mode: 'workspace', session_id: nil, isolated: false)
    raise ArgumentError, 'Legacy Live Playground is unavailable; reset the session' if mode.to_s == 'live'

    @account = account
    @user = user
    @fresh_isolated = isolated && session_id.blank?
    @initial_id = "#{Captain::Playground::SessionStore::ISOLATED_PREFIX}#{SecureRandom.uuid}" if @fresh_isolated
    @requested_id = session_id.presence
    @store = Captain::Playground::SessionStore.new(
      account: account, user: user, mode: mode, session_id: @initial_id || @requested_id
    )
  end

  def mode = 'workspace'
  def trial? = true
  def live? = false
  def conversation = nil
  def deep_dup = self

  # Choosing a channel gives the agents of that channel (a text channel: every enabled agent; a voice number: its voice agent alone).
  # Without a channel the enabled agents of the workspace work as in a text channel.
  def routing_inbox
    return if data.to_h['inbox_id'].blank?

    account.inboxes.find_by(id: data['inbox_id'])
  end

  def scope
    Captain::ChannelScope.for_playground(account, routing_inbox)
  end

  def graph
    Captain::AgentGraph.new(scope)
  end

  def with_lock(reset: false, scenario_input: nil, inbox_id: nil, **)
    store.with_lock do
      load_data!(reset: reset, scenario_input: scenario_input)
      select_routing_inbox!(inbox_id)
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
    { session_id: id, mode: mode, account_id: account.id, user_id: user.id, assistant_id: @reference_assistant_id || assistant&.id }
  end

  # The same session, with the owner of a council part as the acting agent. The part's owner is not the agent that holds the
  # conversation, so it passes the checks of the session as itself (it must still be an enabled agent of the channel), while the
  # session keeps its active agent and the references of the run. Data, ledger and scenario are the session's own.
  def acting_as(actor_id)
    ensure_membership!
    actor = account.captain_assistants.find_by(id: actor_id)
    raise Pundit::NotAuthorizedError, 'Agent belongs to another workspace' unless actor
    raise Pundit::NotAuthorizedError, 'Agent is disabled or not an agent of this Playground channel' unless graph.find(actor.id)

    dup.tap { |view| view.part_view!(actor, reference_assistant_id: @reference_assistant_id || assistant&.id) }
  end

  def part_view!(actor, reference_assistant_id:)
    @assistant = actor
    @reference_assistant_id = reference_assistant_id
    @part_view = true
    @run_policy = nil
  end

  def activate_agent!(actor)
    ensure_membership!
    raise Pundit::NotAuthorizedError, 'Agent belongs to another workspace' unless actor.account_id == account.id

    raise Pundit::NotAuthorizedError, 'Agent is disabled or not an agent of this Playground channel' unless graph.find(actor.id)

    @assistant = actor
    data['active_assistant_id'] = actor.id
    @run_policy = nil
    assistant
  end

  def validate_active_agent!
    ensure_membership!
    raise Pundit::NotAuthorizedError, 'No agent is active in this Playground session' if assistant.nil?

    assistant.reload
    # The owner of a council part is not the session's active agent; it only has to be an enabled agent of the channel.
    active = @part_view || data['active_assistant_id'].to_i == assistant.id
    raise Pundit::NotAuthorizedError, 'Agent is disabled or not an agent of this Playground channel' unless active && graph.find(assistant.id)

    assistant
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

    actor_id = state.to_h.with_indifferent_access[:assistant_id]
    raise ArgumentError, 'Playground acting agent changed' if actor_id.present? && actor_id.to_i != assistant&.id

    validate_active_agent!
  end

  def run_policy
    @run_policy ||= Outbound::PlaygroundDeliveryPolicy.issue(
      mode: mode, run_id: SecureRandom.uuid, session_id: id, account_id: account.id,
      user_id: user.id, assistant_id: assistant&.id, delivery_enabled: false
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
    history << { role: 'assistant', content: response['response'].to_s.first(MAX_MESSAGE_LENGTH), agent_name: response['agent_name'],
                 agent_id: response['agent_id'], agent_display_name: response['agent_display_name'] }.compact
    data['history'] = history.last(MAX_HISTORY)
    data['history'].shift(2) while JSON.generate(data['history']).bytesize > 160_000
  end

  def payload
    current = permissions
    pending = Array(data['action_previews']).select do |preview|
      preview['status'] == 'pending' && current['write'] == true && preview['generation'] == current['generation'] &&
        preview['expires_at'].to_i > Time.current.to_i && preview['binding'] == context_reference.stringify_keys
    end
    { session_id: id, mode: mode, scenario: namespace.encode(scenario.public_data(mode: mode)),
      message_history: data['history'], real_data_read: current['read'] == true, real_data_write: current['write'] == true,
      delivery_enabled: false, action_previews: pending.map { |preview| preview.except('generation') },
      expires_in: Captain::Playground::SessionStore::TTL }
  end

  private

  def load_data!(reset:, scenario_input:)
    @data = @fresh_isolated || reset ? nil : store.read(session_id: @requested_id)
    fresh = reset || @data.nil?
    if fresh
      store.delete_isolated(@requested_id) if reset && @requested_id.present?
      @data = new_data(id: reset ? reset_session_id : (@initial_id || SecureRandom.uuid))
    end
    @namespace = Captain::Playground::SyntheticNamespace.new(id)
    @scenario = Captain::Playground::Scenario.new(data['scenario'])
    @assistant = account.captain_assistants.find_by(id: data['active_assistant_id'].to_i) if data['active_assistant_id'].present?
    @run_policy = nil
    scenario.apply(namespace.decode(scenario_input), mode: mode) if scenario_input.present?
    if scenario_input.present?
      Array(data['action_previews']).each { |preview| preview['status'] = 'revoked' if preview['status'] == 'pending' }
    end
    return unless fresh

    save!
    store.set_permissions(session_id: id, read: false, write: false)
  end

  def reset_session_id
    return "#{Captain::Playground::SessionStore::ISOLATED_PREFIX}#{SecureRandom.uuid}" if @requested_id.to_s.start_with?(
      Captain::Playground::SessionStore::ISOLATED_PREFIX
    )

    SecureRandom.uuid
  end

  def new_data(id: SecureRandom.uuid)
    configuration = account.crm_field_definitions.active.ordered.map do |definition|
      definition.attributes.slice('entity_kind', 'key', 'label', 'field_type', 'required', 'default_value', 'description', 'options', 'rules',
                                  'active', 'position')
    end
    { 'id' => id, 'version' => 2, 'mode' => mode,
      'scenario' => Captain::Playground::Scenario.default(timezone: account.reporting_timezone).merge('custom_fields' => configuration),
      'history' => [], 'action_previews' => [] }
  end

  def select_routing_inbox!(inbox_id)
    return if inbox_id.blank?

    inbox = account.inboxes.find_by(id: inbox_id)
    raise ArgumentError, 'Playground channel is not available' unless inbox
    return if data['inbox_id'].to_i == inbox.id

    # Switching channels starts again with no agent: the router picks one. The previous channel's task state is dropped and pending
    # previews are revoked.
    data['inbox_id'] = inbox.id
    data.delete('active_assistant_id')
    data.delete(Captain::Conversation::AgentSession::ATTRIBUTE)
    Array(data['action_previews']).each { |preview| preview['status'] = 'revoked' if preview['status'] == 'pending' }
    @assistant = nil
    @run_policy = nil
  end

  def ensure_membership!
    raise Pundit::NotAuthorizedError, 'Workspace membership is required' unless account.account_users.exists?(user_id: user.id)
    raise Pundit::NotAuthorizedError, 'Assistant belongs to another workspace' unless assistant.nil? || assistant.account_id == account.id
  end
end
