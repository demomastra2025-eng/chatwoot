class CommunicationThreadMessageFinder
  DEFAULT_LIMIT = 20
  MAX_AFTER_LIMIT = 100

  def initialize(communication_thread:, current_user:, params: {})
    @communication_thread = communication_thread
    @current_user = current_user
    @current_account = current_user.account
    @params = params
  end

  def perform
    current_messages
  end

  private

  attr_reader :communication_thread, :current_user, :current_account, :params

  def current_messages
    return messages_between(after_id, before_id) if after_id && before_id
    return messages_after(after_id) if after_id
    return messages_before(before_id) if before_id

    latest_messages
  end

  def messages
    Message.chat
           .where(account_id: current_account.id, conversation_id: accessible_conversations.select(:id))
           .includes(:attachments, :sender, sender: { avatar_attachment: [:blob] })
  end

  def messages_after(after_id)
    after_message = cursor_message(after_id)
    scope = ordered_messages(:asc)
    return scope.where('messages.id > ?', after_id).limit(MAX_AFTER_LIMIT) if after_message.blank?

    messages_after_cursor(scope, after_message).limit(MAX_AFTER_LIMIT)
  end

  def messages_before(before_id)
    before_message = cursor_message(before_id)
    scope = ordered_messages(:desc)
    return scope.where('messages.id < ?', before_id).limit(DEFAULT_LIMIT).reverse if before_message.blank?

    messages_before_cursor(scope, before_message).limit(DEFAULT_LIMIT).reverse
  end

  def messages_between(after_id, before_id)
    scope = ordered_messages(:asc)
    scope = apply_after_cursor(scope, after_id, inclusive: true)
    scope = apply_before_cursor(scope, before_id)
    scope.limit(1000)
  end

  def after_id
    params[:after].presence&.to_i
  end

  def before_id
    params[:before].presence&.to_i
  end

  def latest_messages
    messages.reorder('created_at desc', 'id desc').limit(DEFAULT_LIMIT).reverse
  end

  def cursor_message(message_id)
    messages.reorder(nil).find_by(id: message_id)
  end

  def ordered_messages(direction)
    sort_direction = direction == :desc ? 'desc' : 'asc'
    messages.reorder("created_at #{sort_direction}", "id #{sort_direction}")
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

  def accessible_conversations
    @accessible_conversations ||= Conversations::PermissionFilterService.new(
      communication_thread.conversations,
      current_user,
      current_account
    ).perform
  end
end
