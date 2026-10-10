module Captain::Playground::ConversationTools
  private

  def require_conversation!(id = @args['conversation_id'])
    return @data['conversation'] if id.blank? || [@data['conversation']['id'], @data['conversation']['display_id']].map(&:to_s).include?(id.to_s)

    raise ArgumentError, 'Record is not available'
  end

  def conversation_details
    record = require_conversation!(@args.fetch('conversation_id'))
    raise ArgumentError, 'Private messages are not available to this agent profile' if @args['include_private'] == true

    limit = Integer(@args['message_limit'] || 20).clamp(1, 50)
    messages = @data['messages'].reject { |message| message['private'] }.last(limit)
    payload = record.merge('contact_name' => caller['name'], 'messages' => messages.deep_dup,
                           'message_window' => { limit: limit, returned_count: messages.size, truncated: @data['messages'].size > limit,
                                                 private_messages_included: false })
    { conversation: payload, simulated: true }
  end

  def search_conversations
    require_caller_filter!
    status = @args['status']
    priority = @args['priority']
    raise ArgumentError, 'Invalid conversation status' if status && !%w[open resolved pending snoozed].include?(status)
    raise ArgumentError, 'Invalid conversation priority' if priority && !%w[low medium high urgent].include?(priority)

    record = @data['conversation']
    matches = (!status || record['status'] == status) && (!priority || record['priority'] == priority)
    labels = Array(@args['labels']).map { |name| name.to_s.strip }.compact_blank
    matches &&= labels.empty? || labels.intersect?(record['label_list'])
    { conversations: matches ? [record.deep_dup] : [], total_count: matches ? 1 : 0, simulated: true }
  end

  def add_note
    require_conversation!
    text = @args['note'].presence || @args['content'].presence || raise(ArgumentError, 'Note content is required')
    note = { 'id' => @scenario.next_id!, 'contact_id' => caller['id'], 'content' => text, 'private' => @tool_id == 'add_private_note' }
    @data['notes'] << note
    @data['messages'] << note.merge('message_type' => 'outgoing') if note['private']
    { action: @tool_id, contact_id: caller['id'], contact_name: caller['name'], note_id: note['id'], note: text, simulated: true }
  end

  def change_label
    require_conversation!
    name = @args['label_name'].to_s.strip.downcase.presence || raise(ArgumentError, 'A label name is required')
    if @tool_id == 'add_label_to_conversation' && @data['labels'].none? { |label| label['title'].to_s.downcase == name }
      raise ArgumentError, 'Label not found'
    end
    labels = @data['conversation']['label_list']
    @tool_id == 'add_label_to_conversation' ? labels.push(name).uniq! : labels.delete(name)
    { action: @tool_id, conversation_id: @data['conversation']['display_id'], labels: labels.deep_dup, simulated: true }
  end

  def update_priority
    require_conversation!
    priority = @args.fetch('priority')
    raise ArgumentError, 'Invalid priority' unless %w[low medium high urgent none].include?(priority)

    @data['conversation']['priority'] = priority == 'none' ? nil : priority
    { action: @tool_id, priority: @data['conversation']['priority'], simulated: true }
  end

  def resolve_conversation
    require_conversation!
    raise ArgumentError, 'Conversation is already resolved' if @data['conversation']['status'] == 'resolved'
    raise ArgumentError, 'Auto-resolve is disabled for this account' if @session.account.captain_auto_resolve_disabled?

    operation = Captain::Tools::Operations::ConversationOperations.new(assistant: @session.assistant)
    reason = operation.send(:configured_status_reason_for, snapshot_conversation, 'resolved', @args['status_reason'], fallback_reason: @args['reason'])
    @data['conversation']['status'] = 'resolved'
    @data['conversation']['status_reason'] = reason
    { action: @tool_id, conversation_id: @data['conversation']['display_id'], status: 'resolved', simulated: true }
  end

  def simulate_message
    require_conversation!
    %w[target_inbox_id target_contact_inbox_id communication_thread_id].each do |key|
      next if @args[key].blank?
      expected = { 'target_inbox_id' => @data['conversation']['inbox_id'], 'target_contact_inbox_id' => 301,
                   'communication_thread_id' => @data['conversation']['id'] }.fetch(key)
      raise ArgumentError, 'Record is not available' unless @args[key] == expected
    end
    raise ArgumentError, 'Record is not available' if @args['channel_key'].present? && @args['channel_key'] != 'current'
    operation = Captain::Tools::Operations::ConversationOperations.new(assistant: @session.assistant)
    template = operation.send(:parsed_hash, @args['template_params'], field_name: 'template_params')
    kind = operation.send(:normalized_content_kind, @args['content_kind'], template_params: template)
    content = @args['content'].to_s.strip
    attachments = snapshot_attachments
    private_note = ActiveModel::Type::Boolean.new.cast(@args['private_note'])
    operation.send(:validate_message_payload!, content: content, content_kind: kind, template_params: template,
                   attachments: attachments, private_note: private_note)
    snapshot_delivery_policy(content_kind: kind, template_params: template, attachments: attachments, private_note: private_note)
    record!('messages', @args['in_reply_to_message_id']) if @args['in_reply_to_message_id'].present?
    messages = if operation.send(:split_outgoing_attachments?, conversation: snapshot_conversation, content_kind: kind,
                                 private_message: private_note, attachments: attachments)
                 attachments.each_with_index.map { |artifact, index| simulated_message(index.zero? ? content.presence : nil, attachments: [artifact]) }
               else
                 [simulated_message(content.presence, private_note: private_note, template_params: template, attachments: attachments)]
               end
    message = messages.first
    { action: @tool_id, message: message, message_id: message['id'], conversation_id: @data['conversation']['display_id'], simulated: true,
      delivered: false }
  end

  def simulated_message(content, private_note: false, template_params: {}, attachments: [])
    message = { 'id' => @scenario.next_id!, 'content' => content, 'status' => 'sent', 'private' => private_note,
                'message_type' => 'outgoing', 'content_type' => 'text', 'conversation_id' => @data['conversation']['id'],
                'sender_type' => 'Captain::Assistant', 'sender_id' => @session.assistant.id, 'created_at' => Time.current.iso8601,
                'source_id' => "synthetic_#{@session.id}_#{@data['next_id']}", 'content_attributes' => {},
                'template_params' => template_params, 'attachments' => attachments }
    @data['messages'] << message
    message
  end

  def simulate_handoff
    @data['conversation']['status'] = 'open'
    { action: 'handoff', reason: @args['reason'], simulated: true, external_delivery: false }
  end

  def assign_conversation
    record = require_conversation!(@args.fetch('conversation_id'))
    operation = Captain::Tools::Operations::ConversationOperations.new(assistant: @session.assistant)
    account = snapshot_assignment_account
    operation.define_singleton_method(:account) { account }
    if @args['assignee_id'].present? || @args['assignee_type'].present?
      type = operation.send(:validated_assignee_type!, assignee_id: @args['assignee_id'], assignee_type: @args['assignee_type'])
      record.merge!('assignee_id' => @args['assignee_id'], 'assignee_type' => type)
    end
    if @args.key?('team_id')
      account.teams.find(@args['team_id']) if @args['team_id'].present?
      record['team_id'] = @args['team_id']
    end
    { action: @tool_id, conversation: record.deep_dup, simulated: true }
  end

  def send_notification
    require_conversation!
    operation = Captain::Tools::Operations::NotificationOperations.new(assistant: @session.assistant)
    account = snapshot_assignment_account
    operation.define_singleton_method(:account) { account }
    operation.send(:validate_recipient_type!, @args['recipient_type'])
    message = operation.send(:normalize_required_text, @args['message'], field_name: 'message', max_length: operation.class::MAX_MESSAGE_LENGTH)
    title = operation.send(:normalize_optional_text, @args['title'], default: operation.class::DEFAULT_TITLE, max_length: operation.class::MAX_TITLE_LENGTH)
    recipient = operation.send(:find_recipient!, **%w[recipient_id recipient_email recipient_name].index_with { |key| @args[key] }.symbolize_keys)
    notification = { 'id' => @scenario.next_id!, 'notification_type' => 'captain_notification',
      'recipient' => { 'id' => recipient.id, 'name' => recipient.name, 'email' => recipient.email }.compact,
      'title' => title, 'message' => message, 'conversation_id' => @data['conversation']['id'],
      'conversation_display_id' => @data['conversation']['display_id'], 'assistant_id' => @session.assistant.id, 'created_at' => Time.current.iso8601 }
    @data['notifications'] << notification
    { action: @tool_id, notification: notification.deep_dup, simulated: true, delivered: false }
  end

  def retry_failed_message
    record = record!('messages', @args.fetch('message_id'))
    raise ArgumentError, 'Only outgoing messages can be retried' unless record['message_type'] == 'outgoing'
    raise ArgumentError, 'Only failed messages can be retried' unless record['status'] == 'failed'

    record.merge!('status' => 'sent', 'content_attributes' => {})
    { action: @tool_id, message: record.deep_dup, simulated: true, delivered: false }
  end

  def edit_message
    record = record!('messages', @args.fetch('message_id'))
    message = native_snapshot(Message, record)
    load_snapshot_association(message, :conversation, snapshot_conversation)
    attachments = Array(record['attachments']).map { |item| Struct.new(:file_type).new(item.is_a?(Hash) ? item['file_type'] : 'file') }
    load_snapshot_association(message, :attachments, attachments)
    service = Messages::UpdateContentService.new(message: message, content: @args['content'])
    service.send(:validate_message!)
    content = @args['content'].to_s.strip
    raise ArgumentError, 'Message content cannot be blank' if content.blank?

    record.merge!('content' => content, 'content_attributes' => record.fetch('content_attributes', {}).merge('edited' => true))
    { action: @tool_id, message: record.deep_dup, simulated: true, delivered: false }
  rescue Messages::UpdateContentService::Error => e
    raise ArgumentError, e.message
  end

  def cancel_response
    @context.context[:pending_response_cancellation] = { reason: @args['reason'].presence, timestamp: Time.current }.compact
    Captain::Tools::CancelResponseTool.new(@session.assistant).send(:halt, 'response_cancelled')
  end

  def merge_contacts
    base = record!('contacts', @args.fetch('base_contact_id'))
    mergee = record!('contacts', @args.fetch('mergee_contact_id'))
    projections = [base, mergee].map do |record|
      contact_projection(record).tap do |projection|
        appointments = @data['appointments'].select { |item| item['patient_contact_id'] == record['id'] }
        scope = Captain::Playground::RecordSnapshots::SnapshotScope.new(appointments.map { |item| native_snapshot(Scheduling::Appointment, item) })
        projection.define_singleton_method(:patient_scheduling_appointments) { scope }
      end
    end
    ContactMergeAction.new(account: @session.account, base_contact: projections.first, mergee_contact: projections.last).send(:validate_contacts)
    return { action: @tool_id, contact: base.deep_dup, simulated: true } if base['id'] == mergee['id']

    fields = %w[identifier name email phone_number additional_attributes custom_attributes]
    base.merge!(mergee.slice(*fields).compact_blank.deep_merge(base.slice(*fields).compact_blank))
    (@data.values.select { |value| value.is_a?(Array) }.flatten(1) + [@data['conversation']]).each do |record|
      next unless record.is_a?(Hash)
      %w[contact_id patient_contact_id target_contact_id].each { |key| record[key] = base['id'] if record[key] == mergee['id'] }
    end
    @data['caller_contact_id'] = base['id'] if @data['caller_contact_id'] == mergee['id']
    @data['contacts'].delete(mergee)
    @data['grants'].clear
    { action: @tool_id, contact: base.deep_dup, removed_contact_id: mergee['id'], simulated: true }
  rescue Contacts::ReferenceMergeService::UnsafeMergeError => e
    raise ArgumentError, e.message
  end
end
