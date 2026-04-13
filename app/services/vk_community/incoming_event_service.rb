class VkCommunity::IncomingEventService
  pattr_initialize [:channel!, :payload!]

  def perform
    case payload[:type].to_s
    when 'message_new'
      VkCommunity::IncomingMessageService.new(inbox: channel.inbox, params: payload).perform
    when 'message_edit'
      VkCommunity::UpdateMessageService.new(inbox: channel.inbox, params: payload).perform
    end
  end
end
