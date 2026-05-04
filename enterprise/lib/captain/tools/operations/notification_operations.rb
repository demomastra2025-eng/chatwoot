class Captain::Tools::Operations::NotificationOperations < Captain::Tools::Operations::BaseOperation
  DEFAULT_TITLE = 'Captain notification'.freeze
  MAX_TITLE_LENGTH = 140
  MAX_MESSAGE_LENGTH = 2000

  def send_notification(message:, title: nil, recipient_type: nil, recipient_id: nil, recipient_email: nil, recipient_name: nil, conversation_id: nil)
    validate_recipient_type!(recipient_type)

    notification_message = normalize_required_text(message, field_name: 'message', max_length: MAX_MESSAGE_LENGTH)
    notification_title = normalize_optional_text(title, default: DEFAULT_TITLE, max_length: MAX_TITLE_LENGTH)
    target_conversation = find_target_conversation!(conversation_id)
    recipient = find_recipient!(recipient_id: recipient_id, recipient_email: recipient_email, recipient_name: recipient_name)

    create_notification!(
      recipient: recipient,
      conversation: target_conversation,
      title: notification_title,
      message: notification_message
    )
  end

  private

  def validate_recipient_type!(recipient_type)
    type = recipient_type.presence || 'user'
    return if type.to_s == 'user'

    raise ArgumentError, 'recipient_type must be user'
  end

  def normalize_required_text(value, field_name:, max_length:)
    text = value.to_s.strip
    raise ArgumentError, "#{field_name} is required" if text.blank?
    raise ArgumentError, "#{field_name} is too long (maximum #{max_length} characters)" if text.length > max_length

    text
  end

  def normalize_optional_text(value, default:, max_length:)
    text = value.to_s.strip.presence || default
    raise ArgumentError, "title is too long (maximum #{max_length} characters)" if text.length > max_length

    text
  end

  def find_target_conversation!(conversation_id)
    return conversation if conversation_id.blank? && conversation.present?

    raise ArgumentError, 'conversation_id is required when there is no current conversation' if conversation_id.blank?

    account.conversations.find_by(id: conversation_id) || account.conversations.find_by(display_id: conversation_id) ||
      raise(ActiveRecord::RecordNotFound, 'Conversation not found')
  end

  def find_recipient!(recipient_id:, recipient_email:, recipient_name:)
    selectors = {
      recipient_id: recipient_id,
      recipient_email: recipient_email,
      recipient_name: recipient_name
    }.select { |_key, value| value.present? }

    raise ArgumentError, 'Exactly one recipient selector is required' if selectors.size != 1

    case selectors.keys.first
    when :recipient_id
      account.users.find_by(id: recipient_id) || raise(ActiveRecord::RecordNotFound, 'Recipient user not found')
    when :recipient_email
      find_recipient_by_email!(recipient_email)
    when :recipient_name
      find_recipient_by_name!(recipient_name)
    end
  end

  def find_recipient_by_email!(email)
    account.users.where('LOWER(email) = ?', email.to_s.strip.downcase).first ||
      raise(ActiveRecord::RecordNotFound, 'Recipient user not found')
  end

  def find_recipient_by_name!(name)
    normalized_name = name.to_s.strip
    matches = account.users.where('LOWER(name) = ?', normalized_name.downcase).limit(2).to_a
    raise ActiveRecord::RecordNotFound, 'Recipient user not found' if matches.empty?
    raise ArgumentError, 'recipient_name is ambiguous; use recipient_id or recipient_email' if matches.many?

    matches.first
  end

  def create_notification!(recipient:, conversation:, title:, message:)
    Notification.create!(
      account: account,
      user: recipient,
      notification_type: :captain_notification,
      primary_actor: conversation,
      secondary_actor: actor,
      meta: notification_meta(conversation: conversation, recipient: recipient, title: title, message: message)
    )
  end

  def notification_meta(conversation:, recipient:, title:, message:)
    {
      'captain_notification' => {
        'title' => title,
        'message' => message,
        'assistant_id' => assistant.id,
        'recipient_user_id' => recipient.id,
        'actor_user_id' => actor&.id
      }.compact,
      Notification::RENDER_SNAPSHOT_KEY => {
        'push_message_title' => title,
        'push_message_body' => message,
        'primary_actor' => conversation.push_event_data,
        'conversation' => {
          'display_id' => conversation.display_id,
          'inbox_name' => conversation.inbox&.name.to_s,
          'account_id' => account.id
        }
      }
    }
  end
end
