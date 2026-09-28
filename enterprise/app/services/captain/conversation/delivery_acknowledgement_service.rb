class Captain::Conversation::DeliveryAcknowledgementService
  PENDING_ACK_KEY = Captain::Conversation::DeliveryFenceService::PENDING_ACK_KEY
  STATE_KEY = Captain::Conversation::DeliveryFenceService::STATE_KEY

  def initialize(message)
    @message = message
  end

  # The provider receipt and submitted/failed fence state are one durable
  # write. Status and reminder callbacks run separately, outside contact and
  # conversation locks; a retry replays the receipt but never the provider I/O.
  def perform
    @message.reload
    return if @message.additional_attributes.to_h[PENDING_ACK_KEY].blank?

    reminder = Reminder.find_by(id: @message.additional_attributes.to_h['touch_id'], account_id: @message.account_id)
    if reminder
      reminder.with_lock { @message.with_lock { apply_pending_ack! } }
    else
      @message.with_lock { apply_pending_ack! }
    end
  end

  private

  def apply_pending_ack!
    attributes = @message.additional_attributes.to_h
    ack = attributes[PENDING_ACK_KEY].to_h
    status = ack['status']
    return unless valid_ack?(status, attributes[STATE_KEY])

    unless status == 'delivered' && @message.read?
      applied = Messages::StatusUpdateService.new(@message, status, ack['error']).perform
      raise 'Captain provider acknowledgement could not be applied' unless applied && @message.status == status
    end
    @message.update_columns(additional_attributes: attributes.except(PENDING_ACK_KEY)) # rubocop:disable Rails/SkipsModelValidations
  end

  def valid_ack?(status, state)
    (status == 'delivered' && state == 'submitted') || (status == 'failed' && state == 'provider_failed')
  end
end
