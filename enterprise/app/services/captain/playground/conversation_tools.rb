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
    name = @args['label_name'].presence || raise(ArgumentError, 'Label name is required')
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
    @data['conversation']['status'] = 'resolved'
    { action: @tool_id, conversation_id: @data['conversation']['display_id'], status: 'resolved', simulated: true }
  end

  def simulate_message
    require_conversation!
    content = @args['content'].presence || raise(ArgumentError, 'Message content is required')
    message = simulated_message(content)
    { action: @tool_id, message: message, message_id: message['id'], conversation_id: @data['conversation']['display_id'], simulated: true, delivered: false }
  end

  def simulated_message(content)
    message = { 'id' => @scenario.next_id!, 'content' => content, 'status' => 'simulated', 'private' => false,
                'message_type' => 'outgoing', 'content_type' => 'text', 'conversation_id' => @data['conversation']['id'],
                'sender_type' => 'Captain::Assistant', 'sender_id' => @session.assistant.id, 'created_at' => Time.current.iso8601 }
    @data['messages'] << message
    message
  end

  def simulate_handoff
    @data['conversation']['status'] = 'open'
    { action: 'handoff', reason: @args['reason'], simulated: true, external_delivery: false }
  end

  def unsupported_assignment
    { success: false, error: 'No staff assignment exists in this Trial scenario', simulated: true }
  end
end
