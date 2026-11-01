class TelegramPersonal::CreateActivityMessageService
  pattr_initialize [:inbox!, :params!]

  def perform
    return if skip_creation?
    return unless lock_message_source_id!

    set_contact
    return if @contact.blank?

    set_conversation
    create_activity_message
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  private

  def skip_creation?
    chat_id.blank? || message_id.blank? || activity_content.blank? || inbox.messages.exists?(source_id: message_id)
  end

  def set_contact
    @contact_inbox = TelegramPersonal::ContactSyncService.new(
      inbox: inbox,
      params: params
    ).perform
    @contact = @contact_inbox&.contact
  end

  def set_conversation
    @conversation = TelegramPersonal::ConversationSyncService.new(
      inbox: inbox,
      contact_inbox: @contact_inbox,
      activity_at: Time.current,
      additional_attributes: conversation_additional_attributes
    ).perform
  end

  def create_activity_message
    sync_call_conversation_attributes!
    @conversation.messages.create!(
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      message_type: :activity,
      content: activity_content,
      source_id: message_id,
      content_attributes: {
        telegram_activity_type: activity_type,
        telegram_activity_params: activity_params
      }.compact
    )
  end

  def activity_content
    return if activity_type.blank?
    return unless I18n.exists?("conversations.activity.telegram_personal.#{activity_type}")

    I18n.t(
      "conversations.activity.telegram_personal.#{activity_type}",
      contact_name: @contact&.name || peer_user_id.to_s,
      duration_seconds: activity_params[:duration_seconds]
    )
  end

  def activity_type
    params[:activity_type].to_s.presence
  end

  def activity_params
    params[:activity_params].to_h.deep_symbolize_keys
  end

  def message_id
    params[:message_id].to_s.presence
  end

  def chat_id
    params[:chat_id].to_s.presence || peer_user_id.to_s.presence
  end

  def peer_user_id
    params[:peer_user_id] || params[:sender_id] || params[:chat_id]
  end

  def conversation_additional_attributes
    {
      chat_id: chat_id,
      peer_user_id: peer_user_id,
      username: params[:username]
    }.compact
  end

  def sync_call_conversation_attributes!
    return unless activity_type.to_s.end_with?('_voice_call', '_video_call')

    attrs = (@conversation.additional_attributes || {}).merge('call_provider' => 'telegram_personal')
    attrs['call_status'] = activity_call_status unless %w[ringing in-progress].include?(attrs['call_status'].to_s)
    @conversation.update!(additional_attributes: attrs) if attrs != @conversation.additional_attributes
  end

  def activity_call_status
    activity_type.to_s.sub(/_(?:voice|video)_call\z/, '')
  end

  def lock_message_source_id!
    TelegramPersonal::MessageDedupLock.new(
      inbox_id: inbox.id,
      source_id: message_id
    ).acquire!
  end
end
