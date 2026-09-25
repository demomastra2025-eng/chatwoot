class SendReplyJob < ApplicationJob
  # Old worker images poll outbound_messages without the Captain delivery
  # fence. Route every Captain enqueue (including retries by message id) to a
  # queue only the updated outbound worker polls during rolling cutover.
  queue_as do
    argument = arguments.first
    sender_type = if argument.is_a?(Message)
                    argument.sender_type
                  else
                    Message.where(id: argument).pick(:sender_type)
                  end
    sender_type == 'Captain::Assistant' ? 'captain_outbound_messages_v2' : 'outbound_messages'
  end

  CHANNEL_SERVICES = {
    'Channel::TwitterProfile' => ::Twitter::SendOnTwitterService,
    'Channel::TwilioSms' => ::Twilio::SendOnTwilioService,
    'Channel::Line' => ::Line::SendOnLineService,
    'Channel::Telegram' => ::Telegram::SendOnTelegramService,
    'Channel::TelegramPersonal' => ::TelegramPersonal::SendOnTelegramPersonalService,

    'Channel::Weixin' => ::Weixin::SendOnWeixinService,
    'Channel::Whatsapp' => ::Whatsapp::SendOnWhatsappService,
    'Channel::WhatsappWeb' => ::WhatsappWeb::SendOnWhatsappWebService,
    'Channel::VkCommunity' => ::VkCommunity::SendOnVkCommunityService,
    'Channel::Sms' => ::Sms::SendOnSmsService,
    'Channel::Instagram' => ::Instagram::SendOnInstagramService,
    'Channel::Tiktok' => ::Tiktok::SendOnTiktokService,
    'Channel::Email' => ::Email::SendOnEmailService,
    'Channel::WebWidget' => ::Messages::SendEmailNotificationService,
    'Channel::Api' => ::Messages::SendEmailNotificationService
  }.freeze

  def perform(message_id)
    message = Message.find(message_id)
    return unless message.outgoing?
    return if message.sender_type == 'Captain::Assistant' && message.private?

    if message.sender_type == 'Captain::Assistant'
      return Captain::Conversation::DeliveryFenceService.new(message).perform { dispatch(message) }
    end

    dispatch(message)
  end

  private

  def dispatch(message)

    channel_name = message.conversation.inbox.channel.class.to_s

    if channel_name == 'Channel::FacebookPage'
      send_on_facebook_page(message)
      return message.reload.failed? ? :outcome_unknown : :attempted
    end

    service_class = CHANNEL_SERVICES[channel_name]
    return :unsupported unless service_class

    service_class.new(message: message).perform
    # Some channel adapters absorb transport errors and mark the Message failed
    # instead of raising. No provider receipt means an attempted Captain send
    # is ambiguous, never a successful submission or a safe automatic retry.
    message.reload.failed? ? :outcome_unknown : :attempted
  end

  def send_on_facebook_page(message)
    if message.conversation.additional_attributes['type'] == 'instagram_direct_message'
      ::Instagram::Messenger::SendOnInstagramService.new(message: message).perform
    else
      ::Facebook::SendOnFacebookService.new(message: message).perform
    end
  end
end
