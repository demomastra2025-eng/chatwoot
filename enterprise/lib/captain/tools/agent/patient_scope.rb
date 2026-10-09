class Captain::Tools::Agent::PatientScope
  class Denied < StandardError; end

  ADAPTER_ID_TOOLS = {
    'get_appointment' => [:appointments, :appointment_id, 'appointment'],
    'get_appointment_provider_status' => [:provider_commands, :provider_command_id, 'appointment'],
    'get_contact' => [:contacts, :contact_id, 'contact'],
    'get_deal' => [:deals, :deal_id, 'deal'],
    'list_deal_stages' => [:deals, :deal_id, 'deal']
  }.freeze
  FILTER_TOOLS = %w[search_appointments search_deals search_conversations].freeze
  PUBLIC_RECORD_TOOLS = %w[
    add_contact_note add_private_note add_label_to_conversation update_priority resolve_conversation
    update_contact create_deal update_deal transition_deal_stage
    request_confirmation get_confirmation_request resolve_confirmation
    create_appointment update_appointment cancel_appointment
  ].freeze

  FAILURE = Captain::ToolResult.failure_output(
    error: 'Record is not available', data: { code: 'record_not_available' }, retryable: false
  ).freeze

  attr_reader :conversation

  def initialize(assistant:, conversation:)
    @assistant = assistant
    @conversation = conversation
  end

  def contact_id
    return @contact_id if defined?(@contact_id)
    return @contact_id = nil if conversation&.contact_id.blank?

    @contact_id = @assistant.account.contacts.where(id: conversation&.contact_id).pick(:id)
  end

  def appointments
    scope = @assistant.account.scheduling_appointments
    return scope.none if contact_id.blank?

    scope.where(contact_id: contact_id).or(scope.where(conversation_id: conversation.id))
  end

  def deals
    scope = @assistant.account.crm_deals
    return scope.none if contact_id.blank?

    scope.where(id: ::Crm::DealContact.where(account_id: @assistant.account_id, contact_id: contact_id).select(:deal_id))
  end

  def contacts
    @assistant.account.contacts.where(id: contact_id)
  end

  def conversations
    scope = @assistant.account.conversations
    return scope.none if contact_id.blank?

    scope.where(contact_id: contact_id)
  end

  def provider_commands
    Integrations::Medelement::ProviderCommand.where(account_id: @assistant.account_id, appointment_id: appointments.select(:id))
  end

  def authorize_adapter_tool!(tool, params)
    if ADAPTER_ID_TOOLS.key?(tool)
      scope_name, argument_name, kind = ADAPTER_ID_TOOLS.fetch(tool)
      id = params[argument_name]
      require_id!(public_send(scope_name), id, tool: tool, kind: kind) if tool != 'list_deal_stages' || id.present?
    elsif FILTER_TOOLS.include?(tool)
      require_contact_filter!(params[:contact_id], tool: tool)
    end
  end

  def authorize_public_tool!(tool, params, state)
    ensure_current_contact!(tool)

    case tool
    when 'update_appointment', 'cancel_appointment'
      require_id!(appointments, params[:appointment_id], tool: tool, kind: 'appointment') if params[:appointment_id].present?
    when 'update_deal', 'transition_deal_stage'
      authorize_deal_write!(tool, params, state)
    when 'request_confirmation'
      authorize_confirmation_subject!(tool, params[:subject_kind], state)
    when 'get_confirmation_request', 'resolve_confirmation'
      authorize_confirmation_request!(tool, params[:confirmation_request_id])
    end
  end

  def deal_payload(deal)
    payload = ::Crm::PayloadBuilder.ai_deal(deal)
    safe_payload = payload.except(
      :company, :company_id, :next_action, :deal_contacts, :primary_contact, :primary_contact_id,
      :originating_conversation_id, :originating_conversation_display_id,
      :originating_communication_thread_id, :originating_communication_thread_display_id,
      :dialog_id, :dialog_display_id, :dialog_kind, :dialog_status
    )
    if conversations.exists?(id: deal.originating_conversation_id)
      safe_payload[:originating_conversation_id] = payload[:originating_conversation_id]
      safe_payload[:originating_conversation_display_id] = payload[:originating_conversation_display_id]
    end
    safe_payload
  end

  def deal_tool_payload(action:, deal:)
    data = deal_payload(deal)
    {
      action: action, deal_id: data[:id], pipeline_id: data[:pipeline_id],
      stage_id: data[:stage_id], title: data[:title], amount: data[:amount],
      currency: data[:currency], deal: data
    }.compact
  end

  def require_id!(scope, id, tool:, kind:)
    return if id.present? && scope.exists?(id: id)

    deny!(tool: tool, kind: kind)
  end

  def require_contact_filter!(id, tool:)
    return if id.blank? || (contact_id.present? && id.to_s == contact_id.to_s)

    deny!(tool: tool, kind: 'contact')
  end

  def deny!(tool:, kind:)
    publish_denial(tool, kind)
    raise Denied
  end

  private

  def ensure_current_contact!(tool)
    deny!(tool: tool, kind: 'contact') if PUBLIC_RECORD_TOOLS.include?(tool) && contact_id.blank?
  end

  def publish_denial(tool, kind)
    Llm::EventBus.publish(
      'captain.tool.denied',
      feature: 'assistant', tool_name: tool, account_id: @assistant.account_id,
      conversation_id: conversation&.id, contact_id: contact_id,
      id_kind: kind, outcome: 'denied'
    )
  rescue StandardError => e
    Rails.logger.warn("Captain denied-tool event failed: #{e.class}")
  end

  def authorize_deal_write!(tool, params, state)
    current_deal_id = Captain::ContextFields.deal_for(account: @assistant.account, conversation: conversation)&.id
    deal_id = tool == 'update_deal' ? params[:deal_id].presence || current_deal_id : current_deal_id
    require_id!(deals, deal_id, tool: tool, kind: 'deal')

    state_deal_id = state&.dig(:deal, :id)
    require_id!(deals, state_deal_id, tool: tool, kind: 'deal') if tool == 'transition_deal_stage' && state_deal_id.present?
  end

  def authorize_confirmation_subject!(tool, kind, state)
    case kind.to_s.demodulize.underscore
    when 'appointment'
      require_id!(appointments, state&.dig(:appointment, :id), tool: tool, kind: 'appointment')
    when 'deal'
      require_id!(deals, state&.dig(:deal, :id), tool: tool, kind: 'deal')
    when 'task'
      deny!(tool: tool, kind: 'task')
    end
  end

  def authorize_confirmation_request!(tool, id)
    requests = ConfirmationRequest.where(account_id: @assistant.account_id, conversation_id: conversation.id)
    request = selected_confirmation_request(requests, id)
    return if request.blank? && tool == 'get_confirmation_request' && id.blank?

    deny!(tool: tool, kind: 'conversation') unless request && confirmation_contact_available?(request)
    authorize_confirmation_subject_record!(tool, request.subject)
  end

  def selected_confirmation_request(requests, id)
    return requests.find_by(id: id) if id.present?

    requests.order(created_at: :desc, id: :desc).first
  end

  def confirmation_contact_available?(request)
    request.contact_id.blank? || request.contact_id == contact_id
  end

  def authorize_confirmation_subject_record!(tool, subject)
    case subject
    when nil
      nil
    when Scheduling::Appointment
      require_id!(appointments, subject.id, tool: tool, kind: 'appointment')
    when Crm::Deal
      require_id!(deals, subject.id, tool: tool, kind: 'deal')
    when Conversation
      require_id!(conversations, subject.id, tool: tool, kind: 'conversation')
    else
      deny!(tool: tool, kind: 'task')
    end
  end
end
