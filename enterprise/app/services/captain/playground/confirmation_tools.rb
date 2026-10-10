module Captain::Playground::ConfirmationTools
  SUBJECT_COLLECTIONS = { 'Scheduling::Appointment' => 'appointments', 'Crm::Deal' => 'deals', 'Crm::Task' => 'tasks' }.freeze

  private

  def request_confirmation
    raise ArgumentError, 'Confirmation title and body are required' if @args['title'].blank? || @args['body'].blank?
    raise ArgumentError, 'Confirmation metadata must be an object' if @args['metadata'] && !@args['metadata'].is_a?(Hash)

    key = @args['idempotency_key']
    existing = @data['confirmations'].find { |record| key.present? && record['idempotency_key'] == key }
    record = existing || create_confirmation
    send_now = !@args.key?('send_now') || @args['send_now'] == true
    message = simulated_message(record['body']) if send_now && record['delivery_message_id'].blank?
    record['delivery_message_id'] ||= message&.fetch('id')
    { action: 'request_confirmation', status: 'ok', confirmation_request: record.deep_dup, simulated: true,
      delivery: record['delivery_message_id'] ? { status: 'simulated', message_id: record['delivery_message_id'], delivery_confirmed: false } : nil }.compact
  end

  def create_confirmation
    subject = confirmation_subject
    expiry = parse_time(@args['expires_at']).iso8601 if @args['expires_at'].present?
    record = @args.slice('title', 'body', 'idempotency_key', 'metadata').merge(
      'id' => @scenario.next_id!, 'status' => 'pending', 'contact_id' => caller['id'],
      'conversation_id' => @data['conversation']['id'], 'subject' => subject, 'expires_at' => expiry
    ).compact
    @data['confirmations'] << record
    record
  end

  def confirmation_subject
    type, id = confirmation_subject_reference
    return if type.blank? && id.blank?

    raise ArgumentError, 'Confirmation subject ID is required' if id.blank?
    if type == 'Conversation'
      record = require_conversation!(id)
    else
      collection = SUBJECT_COLLECTIONS[type] || raise(ArgumentError, 'Unsupported confirmation subject type')
      record = record!(collection, id)
      patient_id = record['patient_contact_id'] || record['contact_id']
      raise ArgumentError, 'Record is not available' unless patient_id == caller['id']
    end
    { type: type, id: record['id'], title: record['title'], status: record['status'] }.compact
  end

  def confirmation_subject_reference
    return [@args['subject_type'], @args['subject_id']] if @args['subject_kind'].blank?

    kind = @args['subject_kind'].to_s.demodulize.underscore
    type = Captain::Tools::Operations::ConfirmationOperations::SUBJECT_TYPES_BY_KIND[kind]
    raise ArgumentError, 'Unsupported confirmation subject kind' unless type

    [type, kind == 'conversation' ? @data['conversation']['id'] : @context.state.dig(kind.to_sym, :id)]
  end

  def get_confirmation_request
    record = @args['confirmation_request_id'] ? record!('confirmations', @args['confirmation_request_id']) : @data['confirmations'].last
    raise ArgumentError, 'Confirmation request not found' unless record

    { action: @tool_id, confirmation_request: record.deep_dup, simulated: true }
  end

  def resolve_confirmation
    record = record!('confirmations', @args.fetch('confirmation_request_id'))
    decision = Confirmations::ResolveService::DECISION_ALIASES[@args['decision']]
    raise ArgumentError, 'Invalid confirmation decision' unless decision
    raise ArgumentError, 'Invalid confirmation source' unless ConfirmationRequest::RESOLUTION_SOURCES.include?(@args['source'])
    raise ArgumentError, 'Confirmation metadata must be an object' if @args['metadata'] && !@args['metadata'].is_a?(Hash)

    return { action: @tool_id, confirmation_request: record.deep_dup, simulated: true } if record['status'] == decision
    raise ArgumentError, 'Confirmation has already been resolved' unless record['status'] == 'pending'
    if record['expires_at'] && parse_time(record['expires_at']) <= Time.current
      record['status'] = 'expired'
      return Captain::ToolResult.failure(error: 'Confirmation request expired', retryable: false)
    end
    record.merge!('status' => decision, 'resolved_at' => Time.current.iso8601,
                  'resolution' => @args.slice('source', 'confidence', 'metadata'))
    { action: @tool_id, confirmation_request: record.deep_dup, simulated: true }
  end
end
