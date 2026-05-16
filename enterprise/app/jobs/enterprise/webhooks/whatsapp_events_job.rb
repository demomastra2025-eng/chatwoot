module Enterprise::Webhooks::WhatsappEventsJob
  def handle_message_events(channel, params)
    if call_event?(params)
      handle_call_events(channel, params)
      return
    end

    if call_permission_reply?(params)
      handle_call_permission_reply(channel, params)
      return
    end

    super
  end

  private

  def contact_sender_id(params)
    return nil if call_event?(params)

    super
  end

  def call_event?(params)
    params.dig(:entry, 0, :changes, 0, :field) == 'calls'
  end

  def call_permission_reply?(params)
    message = params.dig(:entry, 0, :changes, 0, :value, :messages, 0)
    message&.dig(:type) == 'interactive' && message&.dig(:interactive, :type) == 'call_permission_reply'
  end

  def handle_call_events(channel, params)
    value = extract_call_params(params)

    Array(value[:calls]).each do |call_payload|
      with_call_lock(channel, call_payload[:id]) do
        Whatsapp::IncomingCallService.new(inbox: channel.inbox, params: { calls: [call_payload] }).perform
      end
    end

    Array(value[:statuses]).each do |status_payload|
      next unless status_payload[:type] == 'call'

      with_call_lock(channel, status_payload[:id]) do
        Whatsapp::IncomingCallService.new(inbox: channel.inbox, params: { statuses: [status_payload] }).perform
      end
    end
  end

  def handle_call_permission_reply(channel, params)
    Whatsapp::CallPermissionReplyService.new(inbox: channel.inbox, params: params).perform
  end

  def with_call_lock(channel, call_id, &)
    lock_key = format(::Redis::Alfred::WHATSAPP_MESSAGE_MUTEX,
                      inbox_id: channel.inbox.id, sender_id: "call:#{call_id}")
    with_lock(lock_key, 30.seconds, &)
  end

  def extract_call_params(params)
    params.dig(:entry, 0, :changes, 0, :value) || {}
  end
end
