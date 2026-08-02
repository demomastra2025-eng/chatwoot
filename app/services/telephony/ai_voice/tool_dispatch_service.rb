require 'timeout'

class Telephony::AiVoice::ToolDispatchService
  class UnknownToolError < StandardError; end

  REALTIME_FAQ_LOOKUP_TIMEOUT_MS = 10_000
  REALTIME_CAPTAIN_TOOL_TIMEOUT_MS = 15_000
  REALTIME_FAQ_LOOKUP_FOREGROUND_WAIT_MS = 900
  VOICE_CONTEXT_CAPTAIN_CATALOG_TIMEOUT_SECONDS = 0.5

  VOICE_CRM_MUTATION_GUIDANCE = {
    'add_contact_note' => [
      'For voice calls, write customer-provided phone data only after the caller finishes,',
      'the full country-code number is repeated back, and the caller explicitly confirms it.'
    ].join(' '),
    'create_deal' => [
      'For voice calls, use the actual call channel as the CRM source;',
      'never infer Telegram, WhatsApp, or another messaging source from a template.'
    ].join(' ')
  }.freeze
  CRM_CHANNEL_SOURCE_PATTERNS = {
    telegram: /(?:(?:лид|заявк[а-я]*|обращени[а-я]*|lead)\s+(?:из|с|from)\s+|(?:источник|source)\s*[:=-]?\s*)(?:telegram|телеграм)/i,
    whatsapp: /(?:(?:лид|заявк[а-я]*|обращени[а-я]*|lead)\s+(?:из|с|from)\s+|(?:источник|source)\s*[:=-]?\s*)(?:whatsapp|ватсап|вотсап)/i,
    instagram: /(?:(?:лид|заявк[а-я]*|обращени[а-я]*|lead)\s+(?:из|с|from)\s+|(?:источник|source)\s*[:=-]?\s*)(?:instagram|инстаграм)/i,
    facebook: /(?:(?:лид|заявк[а-я]*|обращени[а-я]*|lead)\s+(?:из|с|from)\s+|(?:источник|source)\s*[:=-]?\s*)(?:facebook|фейсбук)/i
  }.freeze
  VOICE_PHONE_CONTEXT_PATTERN = /(?:телефон|phone|мобильн|whatsapp|ватсап)/i
  VOICE_PHONE_CANDIDATE_PATTERN = /\+?[\d\s().-]{5,}/

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
          email: { type: 'string', description: 'Customer email' },
          voice_caller_confirmed: {
            type: 'boolean',
            description: 'True only after the caller explicitly confirms a dictated phone number'
          }
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
      description: 'End the current voice call when the caller asks to hang up or the conversation is complete. ' \
                   'Never ask for confirmation and do not announce the hangup: runtime speaks the configured closing message before disconnecting.',
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

  def self.catalog(policy: nil, captain_assistant: nil, voice_settings: nil)
    settings = normalized_voice_settings(policy, captain_assistant, voice_settings)
    voice_tools = VOICE_TOOL_CATALOG.filter_map do |tool|
      next if tool[:name] == 'request_transfer' && settings['manager_handoff_mode'] == 'disabled'

      contextualized_tool = tool.deep_dup
      if contextualized_tool[:name] == 'request_transfer'
        contextualized_tool[:description] = transfer_tool_description(settings['manager_handoff_mode'])
      end
      contextualized_tool.merge(enabled: true, source: 'voice', scope: 'default').deep_stringify_keys
    end

    (voice_tools + bounded_captain_tool_catalog(captain_assistant)).uniq { |tool| tool['name'] }
  end

  def self.normalized_voice_settings(policy, captain_assistant, explicit_settings)
    return Telephony::AiVoice::VoiceSettingsDefaults.normalize(explicit_settings) if explicit_settings.present?

    policy_settings = (policy&.ai_voice_settings || {}).deep_stringify_keys
    assistant_settings = (captain_assistant&.config&.dig('voice_settings') || {}).deep_stringify_keys
    Telephony::AiVoice::VoiceSettingsDefaults.normalize(policy_settings.merge(assistant_settings))
  end

  def self.transfer_tool_description(mode)
    if mode == 'callback'
      'Hand the conversation to a manager for a callback. Use only after the caller agrees; OneLink will announce the callback and end this call.'
    else
      'Transfer the current call to a manager. Use only after the caller agrees; OneLink will announce and perform the live transfer.'
    end
  end

  def self.bounded_captain_tool_catalog(captain_assistant)
    return [] if captain_assistant.blank?

    Timeout.timeout(VOICE_CONTEXT_CAPTAIN_CATALOG_TIMEOUT_SECONDS) do
      Captain::Mcp::ToolCatalog.with_runtime_cache do
        captain_tool_catalog(captain_assistant)
      end
    end
  rescue Timeout::Error
    Rails.logger.warn("#{name}: Captain MCP catalog timed out for assistant_id=#{captain_assistant.id}; returning local Captain tools")
    Captain::Mcp::ToolCatalog.without_discovery { captain_tool_catalog(captain_assistant) }
  end

  private_class_method :normalized_voice_settings, :transfer_tool_description, :bounded_captain_tool_catalog

  def self.captain_tool_catalog(captain_assistant)
    return [] if captain_assistant.blank?

    Array(captain_tool_definitions(captain_assistant)).filter_map do |tool_definition|
      tool = tool_definition.with_indifferent_access
      tool_id = tool[:id].to_s
      next if tool_id.blank?

      {
        name: tool_id,
        title: tool[:title].presence || tool_id.humanize,
        description: captain_tool_description(tool_id, tool[:description]),
        source: 'captain',
        scope: Captain::ToolAccess::SCOPE_AGENT,
        enabled: true,
        realtime_safe: true,
        timeout_ms: tool_id == 'faq_lookup' ? REALTIME_FAQ_LOOKUP_TIMEOUT_MS : REALTIME_CAPTAIN_TOOL_TIMEOUT_MS,
        foreground_wait_ms: tool_id == 'faq_lookup' ? REALTIME_FAQ_LOOKUP_FOREGROUND_WAIT_MS : nil,
        risk_level: tool[:risk_level],
        parameters: captain_tool_parameters(captain_assistant, tool)
      }.compact.deep_stringify_keys
    end
  end

  def self.captain_tool_definitions(captain_assistant)
    return [] if captain_assistant.blank?

    definitions = if captain_assistant.respond_to?(:voice_runtime_agent_tools)
                    captain_assistant.voice_runtime_agent_tools
                  elsif captain_assistant.respond_to?(:prompt_runtime_agent_tools) && captain_assistant.respond_to?(:direct_agent_tools)
                    (captain_assistant.direct_agent_tools + captain_assistant.prompt_runtime_agent_tools).uniq { |tool| tool[:id].to_s }
                  elsif captain_assistant.respond_to?(:prompt_runtime_agent_tools)
                    captain_assistant.prompt_runtime_agent_tools
                  elsif captain_assistant.respond_to?(:direct_agent_tools)
                    captain_assistant.direct_agent_tools
                  elsif captain_assistant.respond_to?(:allowed_agent_tools)
                    captain_assistant.allowed_agent_tools
                  else
                    []
                  end

    Array(definitions).reject { |tool| tool.with_indifferent_access[:id].to_s == 'handoff' }
  end

  def self.captain_tool_parameters(captain_assistant, tool)
    parameter_definitions = captain_parameter_definitions(captain_assistant, tool)
    properties = {}
    required = []

    parameter_definitions.each do |definition|
      definition = definition.deep_stringify_keys
      name = definition['name'].to_s
      next if name.blank?

      type = json_schema_type(definition['type'])
      properties[name] = {
        type: type,
        description: definition['description'].to_s
      }.compact
      properties[name][:items] = { type: 'string' } if type == 'array'
      required << name if ActiveModel::Type::Boolean.new.cast(definition['required'])
    end

    if tool.with_indifferent_access[:id].to_s == 'add_contact_note'
      properties['voice_caller_confirmed'] = {
        type: 'boolean',
        description: 'Set true only after the caller explicitly confirms the complete phone number repeated back by the assistant.'
      }
    end

    { type: 'object', properties: properties, required: required.presence }.compact
  end

  def self.captain_parameter_definitions(captain_assistant, tool)
    runtime_tool = Captain::ToolCatalog.build_tool(
      tool,
      assistant: captain_assistant,
      scope_name: Captain::ToolAccess::SCOPE_AGENT
    )
    return [] unless runtime_tool.respond_to?(:parameters)

    runtime_tool.parameters.values.map do |parameter|
      {
        'name' => parameter.name.to_s,
        'type' => parameter.type.to_s,
        'description' => parameter.description.to_s,
        'required' => parameter.required
      }
    end
  rescue ArgumentError, KeyError, NameError
    []
  end

  def self.captain_tool_description(tool_id, description)
    if tool_id == 'faq_lookup'
      return 'Search approved FAQ and knowledge base before answering factual company, service, tariff, document, or slogan questions.'
    end

    [description.to_s, VOICE_CRM_MUTATION_GUIDANCE[tool_id]].compact.join(' ')
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

  def captain_assistant_id
    ensure_call_session!
    captain_assistant&.id
  end

  def with_captain_assistant_assignment_lock
    ensure_call_session!

    ActiveRecord::Base.transaction do
      lock_assistant_assignment!
      reset_assistant_assignment_cache!
      yield(captain_assistant&.id)
    end
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
    explicit_phone_number = arguments['phone_number'].presence
    phone_number = explicit_phone_number || call_session&.from_number
    if phone_number.blank?
      raise Telephony::Error.new(code: 'PHONE_NUMBER_REQUIRED', message: 'phone_number is required',
                                 status: :unprocessable_content)
    end
    if explicit_phone_number.present?
      ensure_confirmed_voice_phone!(
        [explicit_phone_number],
        caller_confirmed: arguments['voice_caller_confirmed']
      )
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
    reason = arguments['reason'].presence || 'voice_ai_requested_transfer'
    mode = voice_settings['manager_handoff_mode']
    if mode == 'disabled'
      raise Telephony::Error.new(code: 'MANAGER_HANDOFF_DISABLED', message: 'manager handoff is disabled', status: :unprocessable_content)
    end
    return perform_callback_handoff(reason) if mode == 'callback'

    operator_aor = routing_policy&.resolved_operator_agent_aor
    return transfer_target_missing_result(reason) if operator_aor.blank?

    handoff_conversation(reason)

    {
      action: 'transfer',
      status: 'accepted',
      operator_agent_aor: operator_aor,
      reason: reason,
      message: voice_settings['transfer_message'],
      fallback_action: voice_settings['transfer_failure_mode'],
      fallback_message: voice_settings['transfer_failure_message']
    }
  end

  def perform_callback_handoff(reason)
    ensure_conversation!
    handoff_conversation(reason)

    {
      action: 'callback_handoff',
      status: 'accepted',
      reason: reason,
      message: voice_settings['callback_message']
    }
  end

  def transfer_target_missing_result(reason)
    fallback_mode = voice_settings['transfer_failure_mode']
    if fallback_mode == 'callback'
      return perform_callback_handoff(reason).merge(
        fallback_from: 'transfer',
        message: voice_settings['transfer_failure_message']
      )
    end
    if fallback_mode == 'end_call'
      return {
        action: 'end_call',
        status: 'accepted',
        reason: reason,
        fallback_from: 'transfer',
        message: voice_settings['transfer_failure_message']
      }
    end

    raise Telephony::Error.new(code: 'TRANSFER_TARGET_MISSING', message: 'operator transfer target is not configured',
                               status: :unprocessable_content)
  end

  def handoff_conversation(reason)
    return if conversation.blank?

    conversation.with_lock do
      next if conversation.status == 'open' && conversation.waiting_since.present?

      if captain_assistant.present?
        Captain::Tools::Operations::ConversationOperations.new(
          assistant: captain_assistant,
          conversation: conversation,
          actor: captain_assistant
        ).handoff(reason: reason)
      else
        conversation.with_captain_activity_context(reason: reason, reason_type: :tool) do
          conversation.bot_handoff!(source: 'captain')
        end
      end
    end
  end

  def perform_end_call
    transport_result = nil
    call_session.with_lock do
      call_session.reload
      raise_call_session_terminal! if call_session.terminal?

      transport_result = terminate_transport_call
      call_session.update!(
        status: 'completed',
        ended_at: Time.current,
        ended_by: arguments['ended_by'].presence || 'ai_agent',
        end_reason: arguments['reason'].presence || 'ai_voice_end_call'
      )
    end

    { action: 'end_call', status: call_session.status }.merge(transport_result)
  end

  def raise_call_session_terminal!
    raise Telephony::Error.new(
      code: 'CALL_SESSION_TERMINAL',
      message: 'tool execution is not allowed for a terminal call',
      status: :conflict
    )
  end

  def perform_captain_tool
    ensure_voice_crm_source!
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
      result: tool.execute(captain_tool_context, **captain_tool_execution_arguments)
    }
  rescue ArgumentError => e
    {
      action: 'captain_tool',
      tool_name: tool_name,
      result: Captain::ToolResult.failure_output(error: e)
    }
  end

  def ensure_voice_crm_source!
    return unless tool_name == 'create_deal'

    declared_source = CRM_CHANNEL_SOURCE_PATTERNS.find do |_source, pattern|
      arguments['title'].to_s.match?(pattern)
    end&.first
    return if declared_source.blank? || declared_source == voice_crm_source

    raise Telephony::Error.new(
      code: 'VOICE_CRM_SOURCE_MISMATCH',
      message: 'CRM deal source does not match the current voice call channel',
      status: :unprocessable_content
    )
  end

  def voice_crm_source
    whatsapp_cloud_runtime? ? :whatsapp : :phone
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
        captain_runtime: account.captain_runtime_preferences,
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
    tool_arguments = arguments.to_h.deep_dup
    return tool_arguments.transform_keys(&:to_sym) unless tool_name == 'add_contact_note'

    caller_confirmed = tool_arguments.delete('voice_caller_confirmed')
    phone_candidates = voice_phone_candidates(tool_arguments)
    return tool_arguments.transform_keys(&:to_sym) if phone_candidates.blank?

    ensure_confirmed_voice_phone!(phone_candidates, caller_confirmed: caller_confirmed)
    tool_arguments.transform_keys(&:to_sym)
  end

  def ensure_confirmed_voice_phone!(phone_candidates, caller_confirmed:)
    full_phone_present = phone_candidates.any? do |candidate|
      candidate.strip.start_with?('+') && candidate.gsub(/\D/, '').length.between?(10, 15)
    end
    unless full_phone_present
      raise Telephony::Error.new(
        code: 'VOICE_CRM_PHONE_INCOMPLETE',
        message: 'Confirmed phone number must include a full country code',
        status: :unprocessable_content
      )
    end
    return if ActiveModel::Type::Boolean.new.cast(caller_confirmed)

    raise Telephony::Error.new(
      code: 'VOICE_CRM_PHONE_CONFIRMATION_REQUIRED',
      message: 'Caller confirmation is required before storing phone data',
      status: :unprocessable_content
    )
  end

  def voice_phone_candidates(tool_arguments)
    content = tool_arguments.values_at('content', 'note', 'body').compact.join(' ')
    candidates = content.scan(VOICE_PHONE_CANDIDATE_PATTERN)
    phone_context = content.match?(VOICE_PHONE_CONTEXT_PATTERN)
    explicit_international_number = candidates.any? { |candidate| candidate.strip.start_with?('+') }
    return [] unless phone_context || explicit_international_number

    candidates
  end

  def captain_tool_execution_arguments
    return captain_tool_arguments unless tool_name == 'faq_lookup'

    captain_tool_arguments.merge(semantic: false, voice_realtime: true)
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

  def lock_assistant_assignment!
    assignment_inbox&.lock!
    Telephony::AiVoice::AssistantAssignmentLock.acquire!(assignment_inbox.id) if assignment_inbox.present?
    assignment_captain_inbox&.lock!
    routing_policy&.lock!
  end

  def reset_assistant_assignment_cache!
    inbox = assignment_inbox
    inbox.association(:captain_inbox).reset if inbox.respond_to?(:captain_inbox)
    inbox.association(:captain_assistant).reset if inbox.respond_to?(:captain_assistant)
    remove_instance_variable(:@captain_assistant) if defined?(@captain_assistant)
    remove_instance_variable(:@captain_tool_definition) if defined?(@captain_tool_definition)
    remove_instance_variable(:@captain_runtime_state) if defined?(@captain_runtime_state)
  end

  def assignment_inbox
    @assignment_inbox ||= call_session&.inbox || conversation&.inbox
  end

  def assignment_captain_inbox
    return unless assignment_inbox.respond_to?(:captain_inbox)

    assignment_inbox.captain_inbox
  end

  def inbox_captain_assistant
    inbox = assignment_inbox
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

  def voice_settings
    @voice_settings ||= begin
      policy_settings = (routing_policy&.ai_voice_settings || {}).deep_stringify_keys
      assistant_settings = (captain_assistant&.config&.dig('voice_settings') || {}).deep_stringify_keys
      Telephony::AiVoice::VoiceSettingsDefaults.normalize(policy_settings.merge(assistant_settings))
    end
  end

  def call_session
    @call_session ||= Telephony::AiVoice::CallSessionResolver.new(payload: payload).call_session
  end
end
