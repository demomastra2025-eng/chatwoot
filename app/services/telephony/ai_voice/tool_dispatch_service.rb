class Telephony::AiVoice::ToolDispatchService
  class UnknownToolError < StandardError; end

  TOOL_CATALOG = [
    { name: 'find_contact', timeout_ms: 500, realtime_safe: true },
    { name: 'create_contact', timeout_ms: 800, realtime_safe: true },
    { name: 'create_note', timeout_ms: 800, realtime_safe: true },
    { name: 'update_conversation', timeout_ms: 800, realtime_safe: true },
    { name: 'request_transfer', timeout_ms: 300, realtime_safe: true },
    { name: 'end_call', timeout_ms: 300, realtime_safe: true }
  ].freeze

  def self.catalog(policy: nil)
    TOOL_CATALOG.map do |tool|
      tool.merge(enabled: tool[:name] != 'request_transfer' || policy&.resolved_operator_agent_aor.present?).stringify_keys
    end
  end

  def initialize(tool_name:, payload:)
    @tool_name = tool_name.to_s
    @payload = payload.deep_stringify_keys
  end

  def perform
    raise UnknownToolError, "Unknown voice AI tool: #{tool_name}" unless allowed_tool?

    ensure_call_session!
    send("perform_#{tool_name}")
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
    call_session.update!(
      status: 'completed',
      ended_at: Time.current,
      ended_by: arguments['ended_by'].presence || 'ai_agent',
      end_reason: arguments['reason'].presence || 'ai_voice_end_call'
    )

    { action: 'end_call', status: call_session.status }
  end

  def allowed_tool?
    TOOL_CATALOG.any? { |tool| tool[:name] == tool_name }
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
