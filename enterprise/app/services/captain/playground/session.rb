require 'digest'

class Captain::Playground::Session
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
      @data = @store.read(session_id: reset ? nil : @requested_id)
      @data = new_data if reset || @data.nil?
      @scenario = Captain::Playground::Scenario.new(@data['scenario'])
      @profile_phone_edited = scenario_input&.dig('contact', 'phone_number').present? || scenario_input&.dig(:contact, :phone_number).present?
      @scenario.apply(scenario_input, mode: mode) if scenario_input.present?
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
    raise ArgumentError, 'Playground execution context does not match the server session' unless expected.all? { |key, value| reference[key] == value }
    raise ArgumentError, 'Playground source is required' unless state.to_h.with_indifferent_access[:source] == 'playground'

    return if trial?

    live_state = state.to_h.with_indifferent_access
    raise ArgumentError, 'Playground caller does not match the selected source' unless live_state.dig(:conversation, :id) == conversation.id &&
                                                                                     live_state.dig(:contact, :id) == conversation.contact_id
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
      live_available: administrator?, live_warning: live? ? LIVE_WARNING : nil,
      conversation_id: live? ? conversation.display_id : nil,
      inbox_id: live? ? conversation.inbox_id : nil,
      delivery_enabled: live? && data['delivery_enabled'] == true,
      delivery_target: live? ? data['delivery_target'] : nil,
      inboxes: accessible_inboxes.map { |inbox| { id: inbox.id, name: inbox.name, channel_type: inbox.channel_type } }
    }.compact
  end

  private

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

  def prepare_live!(inbox_id:, delivery_enabled:, delivery_target:)
    inbox = selected_inbox(inbox_id)
    raise ArgumentError, 'Reset the Live session before changing its inbox' if data['inbox_id'].present? && data['inbox_id'] != inbox.id

    data['delivery_enabled'] = ActiveModel::Type::Boolean.new.cast(delivery_enabled) == true
    target = Outbound::PlaygroundDeliveryPolicy.normalize_phone(delivery_target)
    if data['delivery_enabled']
      raise ArgumentError, 'A controlled test phone number is required' unless target
      raise ArgumentError, 'This inbox cannot deliver to a controlled phone number' unless Outbound::PlaygroundDeliveryPolicy::PHONE_CHANNELS.include?(inbox.channel_type)
    end
    data['delivery_target'] = data['delivery_enabled'] ? target : nil
    data['inbox_id'] = inbox.id
    create_live_source!(inbox, target: target) if data['conversation_id'].blank?
    validate_live_source!
    update_live_profile!(target: target)
    @run_policy = nil
    conversation.update_columns(additional_attributes: conversation.additional_attributes.to_h.merge( # rubocop:disable Rails/SkipsModelValidations
      Outbound::PlaygroundDeliveryPolicy::ATTRIBUTE_KEY => run_policy
    ))
  end

  def create_live_source!(inbox, target:)
    profile = scenario.contact
    seed = Digest::SHA256.hexdigest(id).to_i(16).to_s.last(12).rjust(12, '0')
    phone = if data['delivery_enabled']
              target
            else
              @profile_phone_edited ? profile['phone_number'] : "+999#{seed}"
            end
    marker = { 'session_id' => id, 'account_id' => account.id, 'user_id' => user.id, 'assistant_id' => assistant.id }
    source = if Outbound::PlaygroundDeliveryPolicy::PHONE_CHANNELS.include?(inbox.channel_type)
               phone_source(inbox, phone)
             else
               "captain-playground-#{id}"
             end
    account.with_lock do
      Current.with_runtime_events_suppressed do
        contact = account.contacts.build(name: profile['name'], phone_number: phone, identifier: "captain-playground-#{id}",
                                         email: nil, custom_attributes: caller_custom_attributes(profile),
                                         additional_attributes: { 'captain_playground_source' => marker })
        contact.skip_runtime_events = true
        contact.save!
        contact_inbox = contact.contact_inboxes.create!(inbox: inbox, source_id: source, hmac_verified: false)
        @conversation = account.conversations.build(inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                                                   status: :pending, additional_attributes: { 'captain_playground_source' => marker })
        @conversation.skip_runtime_events = true
        @conversation.skip_communication_thread_refresh = true
        @conversation.save!
        data['caller_contact_id'] = contact.id
        data['conversation_id'] = @conversation.id
      end
    end
  end

  def validate_live_source!
    marker = conversation.additional_attributes.to_h['captain_playground_source'].to_h
    contact_marker = conversation.contact.additional_attributes.to_h['captain_playground_source'].to_h
    expected = { 'session_id' => id, 'account_id' => account.id, 'user_id' => user.id, 'assistant_id' => assistant.id }
    raise ArgumentError, 'Live Playground requires its dedicated test caller source' unless marker == expected && contact_marker == expected
    raise ArgumentError, 'Live caller inbox changed' unless conversation.inbox_id == data['inbox_id']
  end

  def update_live_profile!(target:)
    profile = scenario.contact
    phone = if data['delivery_enabled']
              target
            else
              @profile_phone_edited ? profile['phone_number'] : conversation.contact.phone_number
            end
    Current.with_runtime_events_suppressed do
      conversation.contact.update!(name: profile['name'], phone_number: phone,
                                    custom_attributes: caller_custom_attributes(profile))
      source = phone_source(conversation.inbox, phone)
      conversation.contact_inbox.update!(source_id: source, hmac_verified: false) if Outbound::PlaygroundDeliveryPolicy::PHONE_CHANNELS.include?(conversation.inbox.channel_type)
    end
    scenario.data['caller_contact_id'] = conversation.contact_id
    profile.merge!(conversation.contact.attributes.slice(*Captain::ContextFields::CONTACT_STATE_ATTRIBUTES.map(&:to_s)))
    # Live keeps only the native caller profile. Trial identifiers/catalogues never leave its server session.
    data['scenario'] = scenario.data
  end

  def phone_source(inbox, phone)
    return phone if inbox.channel_type == 'Channel::Sms'
    return phone.delete_prefix('+') unless inbox.channel_type == 'Channel::TwilioSms'

    inbox.channel.medium == 'whatsapp' ? "whatsapp:#{phone}" : phone
  end

  def caller_custom_attributes(profile)
    profile['custom_attributes'].to_h.reject { |key, _value| key.match?(/medelement|provider|verified|captain_playground/i) }
  end
end
