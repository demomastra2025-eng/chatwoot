class Messages::HistoryMediaIdentity
  class Changed < StandardError; end

  MESSAGE_FIELDS = %w[id account_id inbox_id conversation_id source_id].freeze

  def initialize(message)
    @identity = identity_for(message)
    @identity = @identity.deep_dup if @identity
  end

  def current?(message)
    return false if @identity.blank? || !message.is_a?(Message)

    message.reload
    @identity == identity_for(message) && available?(message)
  rescue ActiveRecord::RecordNotFound
    false
  end

  def verify!(message)
    raise Changed, 'History media context changed' unless current?(message)

    message
  end

  private

  def identity_for(message)
    inbox = message.inbox
    conversation = message.conversation
    return if inbox.nil? || conversation.nil?

    inbox.reload
    conversation.reload
    channel = inbox.channel
    return if channel.nil?

    channel.reload

    message.attributes.slice(*MESSAGE_FIELDS).merge(
      'inbox_account_id' => inbox.account_id, 'channel_type' => inbox.channel_type, 'channel_id' => inbox.channel_id,
      'channel_account_id' => channel.account_id, 'conversation_account_id' => conversation.account_id,
      'conversation_inbox_id' => conversation.inbox_id
    )
  end

  def available?(message)
    inbox = message.inbox
    channel = inbox.channel
    return false if message.source_id.blank? || message.content_attributes.to_h['deleted'].present? || inbox.deleting?
    return false if channel.respond_to?(:lifecycle_state) && channel.lifecycle_state == 'deleting'

    message.account.reload.active? && ownership_current?(message)
  end

  def ownership_current?(message)
    message.account_id == message.inbox.account_id && message.account_id == message.inbox.channel.account_id &&
      message.account_id == message.conversation.account_id && message.inbox_id == message.conversation.inbox_id
  end
end
