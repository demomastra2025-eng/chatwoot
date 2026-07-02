class MessageFinder
  DEFAULT_LIMIT = 20
  MAX_AFTER_LIMIT = 100
  MAX_BETWEEN_LIMIT = 1000

  def initialize(conversation, params)
    @conversation = conversation
    @params = params
  end

  def perform
    current_messages
  end

  private

  def conversation_messages
    @conversation.messages.includes(:attachments, :sender, sender: { avatar_attachment: [:blob] })
  end

  def messages
    return conversation_messages if @params[:filter_internal_messages].blank?

    conversation_messages.where.not('private = ? OR message_type = ?', true, 2)
  end

  def current_messages
    return messages_between(after_id, before_id) if after_id && before_id
    return messages_before(before_id) if before_id
    return messages_after(after_id) if after_id

    messages_latest
  end

  def after_id
    @params[:after].presence&.to_i
  end

  def before_id
    @params[:before].presence&.to_i
  end

  def messages_after(message_id)
    ordered_messages(:asc)
      .then { |scope| apply_after_cursor(scope, message_id) }
      .limit(MAX_AFTER_LIMIT)
  end

  def messages_before(message_id)
    ordered_messages(:desc)
      .then { |scope| apply_before_cursor(scope, message_id) }
      .limit(DEFAULT_LIMIT)
      .reverse
  end

  def messages_between(after_message_id, before_message_id)
    ordered_messages(:asc)
      .then { |scope| apply_after_cursor(scope, after_message_id, inclusive: true) }
      .then { |scope| apply_before_cursor(scope, before_message_id) }
      .limit(MAX_BETWEEN_LIMIT)
  end

  def messages_latest
    ordered_messages(:desc).limit(DEFAULT_LIMIT).reverse
  end

  def ordered_messages(direction)
    sort_direction = direction == :desc ? 'desc' : 'asc'
    messages.reorder("created_at #{sort_direction}", "id #{sort_direction}")
  end

  def cursor_message(message_id)
    cursor_messages.reorder(nil).select(:id, :created_at).find_by(id: message_id)
  end

  def cursor_messages
    return @conversation.messages if @params[:filter_internal_messages].blank?

    @conversation.messages.where.not('private = ? OR message_type = ?', true, 2)
  end

  def apply_after_cursor(scope, message_id, inclusive: false)
    cursor = cursor_message(message_id)
    return scope.where('messages.id >= ?', message_id) if cursor.blank? && inclusive
    return scope.where('messages.id > ?', message_id) if cursor.blank?

    messages_after_cursor(scope, cursor, inclusive: inclusive)
  end

  def apply_before_cursor(scope, message_id)
    cursor = cursor_message(message_id)
    return scope.where('messages.id < ?', message_id) if cursor.blank?

    messages_before_cursor(scope, cursor)
  end

  def messages_after_cursor(scope, cursor, inclusive: false)
    id_operator = inclusive ? '>=' : '>'
    scope.where(
      "messages.created_at > ? OR (messages.created_at = ? AND messages.id #{id_operator} ?)",
      cursor.created_at,
      cursor.created_at,
      cursor.id
    )
  end

  def messages_before_cursor(scope, cursor)
    scope.where(
      'messages.created_at < ? OR (messages.created_at = ? AND messages.id < ?)',
      cursor.created_at,
      cursor.created_at,
      cursor.id
    )
  end
end
