module Telegram::ParamHelpers
  # ensures that message is from a private chat and not a group chat
  def private_message?
    return true if callback_query_params? && !group_message?

    telegram_params_chat_type == 'private'
  end

  def group_message?
    telegram_params_chat_type.in?(%w[group supergroup])
  end

  def supported_message_chat?
    private_message? || group_message?
  end

  def telegram_params_chat_type
    if callback_query_params?
      params.dig(:callback_query, :message, :chat, :type).to_s
    else
      params.dig(:message, :chat, :type).to_s
    end
  end

  def telegram_params_chat_title
    if callback_query_params?
      params.dig(:callback_query, :message, :chat, :title)
    else
      params.dig(:message, :chat, :title)
    end
  end

  def telegram_params_content_attributes
    attrs = {}
    reply_to = params.dig(:message, :reply_to_message, :message_id)
    attrs['in_reply_to_external_id'] = reply_to if reply_to
    attrs['group_sender'] = telegram_params_group_sender if group_message? && telegram_params_group_sender.present?
    attrs
  end

  def telegram_params_group_sender
    sender = telegram_params_base_object&.dig(:from)
    return if sender.blank?

    first_name = sender[:first_name].to_s.strip.presence
    last_name = sender[:last_name].to_s.strip.presence
    username = sender[:username].to_s.strip.presence
    sender_id = sender[:id].to_s.presence
    full_name = [first_name, last_name].compact.join(' ').strip.presence || username || sender_id
    return if full_name.blank? && sender_id.blank?

    {
      'id' => sender_id,
      'name' => full_name,
      'first_name' => first_name,
      'last_name' => last_name,
      'username' => username
    }.compact
  end

  def business_message?
    telegram_params_business_connection_id.present?
  end

  # In business bot mode we will receive messages from our telegram.
  # This is our messages posted via telegram client.
  # Such messages should be outgoing (from us to client)
  def business_message_outgoing?
    business_message? && telegram_params_base_object[:chat][:id] != telegram_params_base_object[:from][:id]
  end

  def message_params?
    params[:message].present?
  end

  def callback_query_params?
    params[:callback_query].present?
  end

  def telegram_params_base_object
    if callback_query_params?
      params[:callback_query]
    else
      params[:message]
    end
  end

  def contact_params
    if business_message_outgoing? || group_message?
      telegram_params_base_object[:chat]
    else
      telegram_params_base_object[:from]
    end
  end

  def telegram_params_from_id
    return telegram_params_chat_id if business_message? || group_message?

    telegram_params_base_object[:from][:id]
  end

  def telegram_params_first_name
    contact_params[:first_name]
  end

  def telegram_params_last_name
    contact_params[:last_name]
  end

  def telegram_params_username
    contact_params[:username]
  end

  def telegram_params_language_code
    contact_params[:language_code]
  end

  def telegram_params_chat_id
    if callback_query_params?
      params[:callback_query][:message][:chat][:id]
    else
      telegram_params_base_object[:chat][:id]
    end
  end

  def telegram_params_business_connection_id
    if callback_query_params?
      params[:callback_query][:message][:business_connection_id]
    else
      telegram_params_base_object[:business_connection_id]
    end
  end

  def telegram_params_message_content
    if callback_query_params?
      params[:callback_query][:data]
    else
      params[:message][:text].presence || params[:message][:caption]
    end
  end

  def telegram_params_message_id
    if callback_query_params?
      params[:callback_query][:id]
    else
      params[:message][:message_id]
    end
  end
end
