class SendReplyJob < ApplicationJob
  queue_as :outbound_messages

  retry_on Reminders::RetryableExecutionError, wait: 5.seconds, attempts: :unlimited

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

  def self.perform_now_with_follow_up_finalizer(message_id, &finalizer)
    job = new(message_id)
    job.instance_variable_set(:@follow_up_finalizer, finalizer)
    job.perform_now
  end

  def perform(message_id)
    message = Message.find(message_id)
    return unless message.outgoing?
    Outbound::PlaygroundDeliveryPolicy.ensure!(
      conversation: message.conversation,
      policy: Outbound::PlaygroundDeliveryPolicy.policy_for(conversation: message.conversation, message: message),
      private_note: message.private?
    )

    retry_state = follow_up_retry_state(message) if @follow_up_finalizer.nil?
    if retry_state == :confirmed
      schedule_captain_follow_up_after_retry(message)
      return
    end

    @captain_follow_up_retry = retry_state == :retry
    result = if defined?(Captain::Conversation::FollowUpDispatchGuard)
               Captain::Conversation::FollowUpDispatchGuard.with_provider_boundary(message) do
                 dispatch_and_finalize(message)
               end
             else
               dispatch_and_finalize(message)
             end

    schedule_captain_follow_up_after_retry(message) if @captain_follow_up_retry
    result
  rescue Outbound::PlaygroundDeliveryPolicy::Blocked => e
    message.update!(status: :failed, external_error: e.message)
    false
  end

  private

  def dispatch_and_finalize(message)
    result = dispatch_message(message) unless @captain_follow_up_retry && message.source_id.present?
    if @follow_up_finalizer
      @follow_up_finalizer.call
    elsif @captain_follow_up_retry
      Reminders::DeliverMaterializedMessageJob.finalize_captain_follow_up_retry(message.id)
    else
      result
    end
  end

  def follow_up_retry_state(message)
    attributes = message.additional_attributes.to_h.deep_stringify_keys
    return unless attributes['captain_follow_up'].is_a?(Hash)

    reminder = Reminder.find_by(
      id: attributes['touch_id'],
      account_id: message.account_id,
      action_type: Reminder.action_types.fetch('captain_follow_up')
    )
    return unless reminder&.delivery_dispatched_for?(message.id)

    return :retry if reminder.delivery_stage == 'retry_scheduled'
    return :confirmed if reminder.delivery_stage.in?(%w[provider_accepted delivered read]) && message.source_id.present?
  end

  def schedule_captain_follow_up_after_retry(message)
    attributes = message.additional_attributes.to_h.deep_stringify_keys
    Reminders::DeliverMaterializedMessageJob.schedule_captain_follow_up_after_retry(
      attributes['touch_id'],
      message.id
    )
  end

  def dispatch_message(message)
    channel_name = message.conversation.inbox.channel.class.to_s

    return send_on_facebook_page(message) if channel_name == 'Channel::FacebookPage'

    service_class = CHANNEL_SERVICES[channel_name]
    return unless service_class

    service_class.new(message: message).perform
  end

  def send_on_facebook_page(message)
    if message.conversation.additional_attributes['type'] == 'instagram_direct_message'
      ::Instagram::Messenger::SendOnInstagramService.new(message: message).perform
    else
      ::Facebook::SendOnFacebookService.new(message: message).perform
    end
  end
end
