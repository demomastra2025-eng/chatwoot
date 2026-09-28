class SendReplyJob < ApplicationJob
  # Old workers do not know the Captain delivery claim. They must not consume
  # Captain jobs while a rolling upgrade is in progress.
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

    return Captain::Conversation::DeliveryFenceService.new(message).perform { dispatch(message) } if message.sender_type == 'Captain::Assistant'

    dispatch(message)
  end

  private

  def dispatch(message)
    channel_name = message.conversation.inbox.channel.class.to_s

    return dispatch_facebook(message) if channel_name == 'Channel::FacebookPage'

    service_class = CHANNEL_SERVICES[channel_name]
    return :unsupported unless service_class

    provider_result = service_class.new(message: message).perform
    message.reload
    return :outcome_unknown if message.failed?
    if message.sender_type == 'Captain::Assistant' && %w[Channel::Line Channel::Tiktok].include?(channel_name)
      return provider_result if provider_result == :delivered || provider_result == :outcome_unknown ||
                                (provider_result.is_a?(Array) && provider_result.first == :provider_failed)

      return :outcome_unknown
    end
    return whatsapp_delivery_result(message) if channel_name == 'Channel::Whatsapp'
    # These adapters persist a provider id only after an acknowledged send.
    # A blank receipt is ambiguous (including a worker crash after the HTTP
    # call), not proof of delivery and never a reason to send Captain twice.
    if message.sender_type == 'Captain::Assistant' &&
       %w[Channel::Telegram Channel::TelegramPersonal Channel::WhatsappWeb].include?(channel_name) && message.source_id.blank?
      return :outcome_unknown
    end

    :attempted
  end

  def whatsapp_delivery_result(message)
    return whatsapp_cloud_delivery_result(message) if message.inbox.channel.provider == 'whatsapp_cloud'
    return :attempted unless message.sender_type == 'Captain::Assistant'
    return :outcome_unknown if Whatsapp::Providers::Whatsapp360DialogService.delivery_outcome_unknown?(message) || message.source_id.blank?

    :attempted
  end

  def whatsapp_cloud_delivery_result(message)
    return :deferred if Whatsapp::Providers::WhatsappCloudService.transient_send_retry_scheduled?(message)
    return :outcome_unknown if Whatsapp::Providers::WhatsappCloudService.delivery_outcome_unknown?(message) || message.source_id.blank?

    :attempted
  end

  def dispatch_facebook(message)
    send_on_facebook_page(message)
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
