class Whatsapp::TemplateFlowButtonParameterService
  MISSING_FLOW_REFERENCE_ERROR = 'WhatsApp Flow template button requires flow_session_id or whatsapp_flow_id'.freeze
  INVALID_FLOW_SESSION_ERROR = 'WhatsApp Flow session does not belong to this conversation'.freeze

  pattr_initialize [:channel!, :button!, :message, :index]

  def call
    persist_session_reference! if should_persist_session_reference?

    {
      type: 'action',
      action: {
        flow_token: flow_session.token,
        flow_action_data: flow_action_data
      }
    }
  end

  private

  def flow_session
    @flow_session ||= existing_flow_session || create_flow_session
  end

  def existing_flow_session
    session_id = button_value('flow_session_id') || button_value('session_id')
    return if session_id.blank?

    session = Whatsapp::FlowSession.find_by(id: session_id, account_id: account.id, inbox_id: inbox.id)
    raise ArgumentError, MISSING_FLOW_REFERENCE_ERROR if session.blank?
    raise ArgumentError, INVALID_FLOW_SESSION_ERROR unless session_belongs_to_message_context?(session)

    session
  end

  def create_flow_session
    flow.flow_sessions.create!(
      account: account,
      inbox: inbox,
      conversation: message&.conversation,
      message: message,
      request_payload: { flow_action_data: flow_action_data },
      metadata: { template_button_index: index }
    )
  end

  def flow
    @flow ||= begin
      flow_record = find_flow_record
      raise ArgumentError, MISSING_FLOW_REFERENCE_ERROR if flow_record.blank?

      flow_record
    end
  end

  def find_flow_record
    flow_id = button_value('whatsapp_flow_id') || button_value('flow_record_id') || local_flow_id_from_parameter
    return inbox.whatsapp_flows.find_by(id: flow_id) if flow_id.present?

    provider_flow_id = button_value('provider_flow_id') || button_value('flow_id') || provider_flow_id_from_parameter
    return inbox.whatsapp_flows.find_by(provider_flow_id: provider_flow_id) if provider_flow_id.present?

    flow_name = button_value('flow_name')
    return inbox.whatsapp_flows.find_by(name: flow_name) if flow_name.present?
  end

  def local_flow_id_from_parameter
    parameter = button_value('parameter')
    return if parameter.blank?
    return unless parameter.to_s.match?(/\A\d+\z/)

    parameter
  end

  def provider_flow_id_from_parameter
    parameter = button_value('parameter')
    return if parameter.blank?
    return if parameter.to_s.match?(/\A\d+\z/)

    parameter
  end

  def flow_action_data
    @flow_action_data ||= begin
      value = button_value('flow_action_data') || button_value('action_data') || button_value('data') || {}
      value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
    end
  end

  def button_value(key)
    button[key] || button[key.to_sym]
  end

  def should_persist_session_reference?
    message.present? && existing_session_reference_blank?
  end

  def existing_session_reference_blank?
    button_value('flow_session_id').blank? && button_value('session_id').blank?
  end

  def persist_session_reference!
    additional_attributes = message.additional_attributes.to_h.deep_dup
    buttons = additional_attributes.dig('template_params', 'processed_params', 'buttons')
    return unless buttons.is_a?(Array)

    button_payload = buttons[index.to_i]
    return unless button_payload.respond_to?(:[]=)

    button_payload['flow_session_id'] = flow_session.id
    message.update!(additional_attributes: additional_attributes)
  end

  def session_belongs_to_message_context?(session)
    return true if message.blank?
    return false if session.conversation_id.present? && session.conversation_id != message.conversation_id
    return false if session.message_id.present? && session.message_id != message.id

    true
  end

  def account
    @account ||= message&.account || inbox.account
  end

  def inbox
    @inbox ||= message&.inbox || channel.inbox
  end
end
