class Telephony::AiVoice::ToolDispatchService
  class UnknownToolError < StandardError; end

  VOICE_TOOL_CATALOG = [
    {
      name: 'find_contact',
      description: 'Find contacts in the current account by phone number, contact id, or text query.',
      timeout_ms: 500,
      realtime_safe: true,
      parameters: {
        type: 'object',
        properties: {
          phone_number: { type: 'string', description: 'Caller or customer phone number' },
          contact_id: { type: 'string', description: 'Existing Chatwoot contact id' },
          query: { type: 'string', description: 'Free-form contact search query' }
        }
      }
    },
    {
      name: 'create_contact',
      description: 'Create or update the caller contact in the current account.',
      timeout_ms: 800,
      realtime_safe: true,
      parameters: {
        type: 'object',
        properties: {
          phone_number: { type: 'string', description: 'Customer phone number' },
          name: { type: 'string', description: 'Customer name' },
          email: { type: 'string', description: 'Customer email' }
        }
      }
    },
    {
      name: 'create_note',
      description: 'Create a private note on the current conversation. The caller does not hear this note.',
      timeout_ms: 800,
      realtime_safe: true,
      parameters: {
        type: 'object',
        properties: { content: { type: 'string', description: 'Private note content' } },
        required: ['content']
      }
    },
    {
      name: 'update_conversation',
      description: 'Update the current Chatwoot conversation status or additional attributes.',
      timeout_ms: 800,
      realtime_safe: true,
      parameters: {
        type: 'object',
        properties: {
          status: { type: 'string', description: 'Conversation status' },
          additional_attributes: { type: 'object', description: 'Additional conversation attributes' }
        }
      }
    },
    {
      name: 'request_transfer',
      description: 'Ask the voice runtime to transfer this call to the configured human operator.',
      timeout_ms: 300,
      realtime_safe: true,
      parameters: {
        type: 'object',
        properties: { reason: { type: 'string', description: 'Reason for transferring to a human operator' } }
      }
    },
    {
      name: 'end_call',
      description: 'End the current voice call when the conversation is complete.',
      timeout_ms: 5_000,
      realtime_safe: true,
      parameters: {
        type: 'object',
        properties: {
          reason: { type: 'string', description: 'Reason for ending the call' },
          ended_by: { type: 'string', description: 'Actor ending the call' }
        }
      }
    }
  ].freeze

  TOOL_CATALOG = VOICE_TOOL_CATALOG.freeze

  def self.catalog(policy: nil, captain_assistant: nil)
    _policy = policy # Reserved for future policy-aware filtering; keep keyword for interface compatibility.

    voice_tools = VOICE_TOOL_CATALOG.map do |tool|
      tool.merge(enabled: true, source: 'voice', scope: 'default').deep_stringify_keys
    end

    (voice_tools + captain_tool_catalog(captain_assistant)).uniq { |tool| tool['name'] }
  end

  def self.captain_tool_catalog(captain_assistant)
    return [] if captain_assistant.blank?

    Array(captain_tool_definitions(captain_assistant)).filter_map do |tool_definition|
      tool = tool_definition.with_indifferent_access
      tool_id = tool[:id].to_s
      next if tool_id.blank?

      {
        name: tool_id,
        title: tool[:title].presence || tool_id.humanize,
        description: tool[:description].to_s,
        source: 'captain',
        scope: Captain::ToolAccess::SCOPE_AGENT,
        enabled: true,
        realtime_safe: true,
        timeout_ms: tool_id == 'faq_lookup' ? 6_000 : 1_000,
        risk_level: tool[:risk_level],
        parameters: captain_tool_parameters(captain_assistant, tool)
      }.compact.deep_stringify_keys
    end
  end

  def self.captain_tool_definitions(captain_assistant)
    return [] if captain_assistant.blank?

    if captain_assistant.respond_to?(:allowed_agent_tools)
      captain_assistant.allowed_agent_tools
    else
      captain_assistant.direct_agent_tools
    end
  end

  def self.captain_tool_parameters(captain_assistant, tool)
    parameter_definitions = captain_parameter_definitions(captain_assistant, tool)
    properties = {}
    required = []

    parameter_definitions.each do |definition|
      definition = definition.deep_stringify_keys
      name = definition['name'].to_s
      next if name.blank?

      properties[name] = {
        type: json_schema_type(definition['type']),
        description: definition['description'].to_s
      }.compact
      required << name if ActiveModel::Type::Boolean.new.cast(definition['required'])
    end

    { type: 'object', properties: properties, required: required.presence }.compact
  end

  def self.captain_parameter_definitions(captain_assistant, tool)
    if ActiveModel::Type::Boolean.new.cast(tool[:custom])
      custom_tool = captain_assistant.account.captain_custom_tools.enabled.find_by(slug: tool[:id].to_s)
      return custom_tool.runtime_parameter_definitions(Captain::ToolAccess::SCOPE_AGENT) if custom_tool
    end

    []
  end

  def self.json_schema_type(type)
    case type.to_s
    when 'number', 'boolean', 'array', 'object'
      type.to_s
    else
      'string'
    end
  end

  def initialize(tool_name:, payload:)
    @tool_name = tool_name.to_s
    @payload = payload.deep_stringify_keys
  end

  def perform
    ensure_call_session!
    return send("perform_#{tool_name}") if voice_tool?
    return perform_captain_tool if captain_tool_definition.present?

    raise UnknownToolError, "Unknown voice AI tool: #{tool_name}"
  end

  private

  attr_reader :tool_name, :payload

  def perform_find_contact
    query = arguments['phone_number'].presence || arguments['query'].presence || call_session&.from_number
    scope = account.contacts
    contacts = if arguments['contact_id'].present?
                 scope.where(id: arguments['contact_id'])
               elsif query.present?
                 normalized = Contacts::PhoneNumberNormalizer.normalize(query)
                 scope.where('phone_number IN (?) OR name ILIKE ?', [query, normalized].compact.uniq, "%#{query}%")
               else
                 scope.none
               end

    {
      contacts: contacts.limit(5).map { |contact| contact_payload(contact) }
    }
  end

  def perform_create_contact
    phone_number = arguments['phone_number'].presence || call_session&.from_number
    if phone_number.blank?
      raise Telephony::Error.new(code: 'PHONE_NUMBER_REQUIRED', message: 'phone_number is required',
                                 status: :unprocessable_content)
    end

    contact = account.contacts.find_or_initialize_by(phone_number: phone_number)
    contact.name = arguments['name'].presence || phone_number if contact.name.blank? || arguments['name'].present?
    contact.email = arguments['email'] if arguments['email'].present?
    contact.save!
    { contact: contact_payload(contact) }
  end

  def perform_create_note
    ensure_conversation!
    content = arguments['content'].to_s.strip
    raise Telephony::Error.new(code: 'NOTE_CONTENT_REQUIRED', message: 'content is required', status: :unprocessable_content) if content.blank?

    message = conversation.messages.create!(
      account_id: account.id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content_type: :text,
      private: true,
      content: content,
      content_attributes: { data: { type: 'ai_voice_note', call_ref: call_session.external_call_ref } }
    )

    { message_id: message.id }
  end

  def perform_update_conversation
    ensure_conversation!
    updates = {}
    status = arguments['status'].to_s.presence
    updates[:status] = status if status.present? && Conversation.statuses.key?(status)

    additional_attributes = (conversation.additional_attributes || {}).deep_dup
    additional_attributes.merge!(arguments['additional_attributes']) if arguments['additional_attributes'].is_a?(Hash)
    additional_attributes['ai_voice_last_tool_at'] = Time.current.iso8601
    updates[:additional_attributes] = additional_attributes

    conversation.update!(updates)
    { conversation_id: conversation.id, status: conversation.status }
  end

  def perform_request_transfer
    operator_aor = routing_policy&.resolved_operator_agent_aor
    if operator_aor.blank?
      raise Telephony::Error.new(code: 'TRANSFER_TARGET_MISSING', message: 'operator transfer target is not configured',
                                 status: :unprocessable_content)
    end

    {
      action: 'transfer',
      operator_agent_aor: operator_aor,
      reason: arguments['reason'].presence || 'voice_ai_requested_transfer',
      message: routing_policy.ai_voice_settings&.dig('transfer_message').presence || 'Сейчас соединю вас со специалистом.'
    }
  end

  def perform_end_call
    transport_result = terminate_transport_call

    call_session.update!(
      status: 'completed',
      ended_at: Time.current,
      ended_by: arguments['ended_by'].presence || 'ai_agent',
      end_reason: arguments['reason'].presence || 'ai_voice_end_call'
    )

    { action: 'end_call', status: call_session.status }.merge(transport_result)
  end

  def perform_captain_tool
    tool = Captain::ToolCatalog.build_tool(
      captain_tool_definition,
      assistant: captain_assistant,
      scope_name: Captain::ToolAccess::SCOPE_AGENT,
      conversation: conversation
    )
    raise UnknownToolError, "Unknown voice AI tool: #{tool_name}" unless tool

    {
      action: 'captain_tool',
      tool_name: tool_name,
      result: tool.execute(captain_tool_context, **captain_tool_arguments)
    }
  end

  def allowed_tool?
    voice_tool? || captain_tool_definition.present?
  end

  def voice_tool?
    VOICE_TOOL_CATALOG.any? { |tool| tool[:name] == tool_name }
  end

  def captain_tool_definition
    @captain_tool_definition ||= begin
      definition = self.class.captain_tool_definitions(captain_assistant).find do |tool_definition|
        tool_definition.with_indifferent_access[:id].to_s == tool_name
      end
      definition&.with_indifferent_access
    end
  end

  def captain_tool_context
    run_context = Captain::Runtime::RunContext.new(
      {
        state: captain_runtime_state,
        current_agent: 'voice_ai'
      }
    )
    Captain::Runtime::ToolContext.new(run_context: run_context)
  end

  def captain_runtime_state
    @captain_runtime_state ||= begin
      state = Captain::ContextFields.runtime_state_for(
        account: account,
        conversation: conversation,
        channel_type: conversation&.inbox&.channel_type
      )
      state.merge!(
        account_id: account.id,
        assistant_id: captain_assistant.id,
        assistant_config: captain_assistant.config,
        captain_runtime: account.captain_preferences[:runtime],
        runtime_clock: runtime_clock_state,
        source: 'voice_ai',
        call_session: { id: call_session.id, external_call_ref: call_session.external_call_ref }
      )
      state[:reply_window] ||= reply_window_state if conversation.present?
      state.compact!
      state[:prompt_context] = captain_assistant.prompt_context_state(state)
      state
    end
  end

  def runtime_clock_state
    timezone = conversation&.inbox&.timezone.presence || Time.zone.name
    timezone = 'UTC' if Time.find_zone(timezone).blank?
    now = Time.current
    local_now = now.in_time_zone(timezone)

    {
      now_utc: now.utc.iso8601,
      now_local: local_now.iso8601,
      timezone: timezone,
      date_local: local_now.to_date.iso8601,
      time_local: local_now.strftime('%H:%M:%S')
    }
  rescue StandardError
    { timezone: 'UTC' }
  end

  def reply_window_state
    return {} unless conversation&.inbox&.channel.is_a?(Channel::Whatsapp)

    last_incoming_at = conversation.messages
                                   .where(account_id: conversation.account_id)
                                   .incoming
                                   .reorder(created_at: :desc)
                                   .limit(1)
                                   .pick(:created_at)
    closes_at = last_incoming_at&.+(Conversations::MessageWindowService::MESSAGING_WINDOW_24_HOURS)

    {
      channel: 'official_whatsapp',
      last_incoming_at: last_incoming_at&.iso8601,
      closes_at: closes_at&.iso8601,
      open_now: closes_at.present? && Time.current < closes_at,
      requires_template_after_close: true
    }.compact
  end

  def captain_tool_arguments
    tool_arguments = arguments.to_h.transform_keys(&:to_sym)
    tool_arguments[:semantic] = false if tool_name == 'faq_lookup'
    tool_arguments
  end

  def terminate_transport_call
    return { transport_terminate_requested: false } unless whatsapp_cloud_runtime?

    whatsapp_call = whatsapp_cloud_call
    return { transport_terminate_requested: false, transport_reason: 'whatsapp_call_not_found' } if whatsapp_call.blank?

    Whatsapp::CallService.new(call: whatsapp_call, agent: nil).terminate
    { transport_terminate_requested: true, whatsapp_call_id: whatsapp_call.id }
  rescue StandardError => e
    Rails.logger.error "[AI VOICE TOOL] Failed to terminate WhatsApp call for session #{call_session.id}: #{e.class.name}: #{e.message}"
    { transport_terminate_requested: false, transport_error: e.class.name }
  end

  def whatsapp_cloud_runtime?
    call_session.provider == 'whatsapp_cloud' ||
      call_session.metadata&.dig('ai_voice', 'transport') == 'whatsapp_cloud' ||
      call_session.metadata&.dig('whatsapp_cloud', 'provider_call_id').present? ||
      call_session.external_call_ref.to_s.start_with?('whatsapp:')
  end

  def whatsapp_cloud_call
    provider_call_id = whatsapp_provider_call_id
    return if provider_call_id.blank?

    scope = Call.whatsapp.where(account_id: account.id, provider_call_id: provider_call_id)
    scope = scope.where(conversation_id: call_session.conversation_id) if call_session.conversation_id.present?
    scope = scope.where(inbox_id: call_session.inbox_id) if call_session.inbox_id.present?
    scope.order(updated_at: :desc).first
  end

  def whatsapp_provider_call_id
    @whatsapp_provider_call_id ||= begin
      metadata_provider_call_id = call_session.metadata&.dig('whatsapp_cloud', 'provider_call_id').presence
      if metadata_provider_call_id.present?
        metadata_provider_call_id
      else
        ref = call_session.external_call_ref.to_s
        if ref.start_with?('whatsapp:')
          ref.delete_prefix('whatsapp:').presence
        elsif call_session.provider == 'whatsapp_cloud'
          ref.presence
        end
      end
    end
  end

  def captain_assistant
    @captain_assistant ||= begin
      assistant = inbox_captain_assistant || routing_policy&.captain_assistant
      assistant if assistant&.account_id == account.id
    end
  end

  def inbox_captain_assistant
    inbox = call_session&.inbox || conversation&.inbox
    return unless inbox.respond_to?(:captain_assistant)

    inbox.captain_assistant
  end

  def contact_payload(contact)
    {
      id: contact.id,
      name: contact.name,
      phone_number: contact.phone_number,
      email: contact.email
    }.compact
  end

  def ensure_conversation!
    return if conversation.present?

    raise Telephony::Error.new(code: 'CONVERSATION_NOT_FOUND', message: 'Unable to resolve conversation for voice tool', status: :not_found)
  end

  def ensure_call_session!
    return if call_session.present?

    raise Telephony::Error.new(code: 'CALL_SESSION_NOT_FOUND', message: 'Unable to resolve call session for voice tool', status: :not_found)
  end

  def arguments
    @arguments ||= (payload['arguments'].is_a?(Hash) ? payload['arguments'] : {}).deep_stringify_keys
  end

  def account
    @account ||= call_session.account
  end

  def conversation
    @conversation ||= call_session&.conversation || account.conversations.find_by(id: payload['conversation_id'])
  end

  def routing_policy
    @routing_policy ||= call_session&.number_binding&.routing_policy || conversation&.inbox&.telephony_number_binding&.routing_policy
  end

  def call_session
    @call_session ||= Telephony::AiVoice::CallSessionResolver.new(payload: payload).call_session
  end
end
