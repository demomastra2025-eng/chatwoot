class Captain::Playground::ReplyDelivery
  def initialize(session)
    @session = session
  end

  def perform(response)
    return { enabled: false, status: 'playground_only', delivered: false } unless @session.live? && @session.data['delivery_enabled'] == true

    content = response.to_h.with_indifferent_access[:response].to_s
    return { enabled: true, status: 'empty', delivered: false } if content.blank?

    policy = Outbound::PlaygroundDeliveryPolicy.for_run(@session.run_policy)
    message = Outbound::PlaygroundDeliveryPolicy.with(policy) do
      Messages::MessageBuilder.new(@session.assistant, @session.conversation, { content: content, message_type: 'outgoing' }).perform
    end
    { enabled: true, status: message.failed? ? 'blocked' : 'queued', delivered: false, message_id: message.id }
  rescue Outbound::PlaygroundDeliveryPolicy::Blocked, ArgumentError => e
    { enabled: true, status: 'blocked', delivered: false, error: e.message }
  end
end
