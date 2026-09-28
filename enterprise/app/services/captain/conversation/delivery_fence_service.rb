require 'timeout'

class Captain::Conversation::DeliveryFenceService
  FENCE_KEY = 'captain_delivery_fence'.freeze
  STATE_KEY = 'captain_delivery_state'.freeze
  PENDING_ACK_KEY = 'captain_delivery_pending_ack'.freeze
  RETRY_ENQUEUED_KEY = 'captain_delivery_retry_enqueued_for'.freeze
  PROVIDER_DISPATCH_DEADLINE = 8

  def self.snapshot(conversation:, assistant:, kind:, trigger_message_id: nil, reminder_id: nil)
    messages = Captain::Conversation::ControlService.contact_messages_scope(conversation)
    # After deliberate AI reactivation, a reminder may follow an earlier
    # human answer. Fence the materialized position; newer activity cancels.
    trigger_message_id ||= (kind == 'reminder' ? messages : messages.incoming).maximum(:id).to_i
    {
      control_generation: conversation.current_captain_control_generation,
      assistant_id: assistant.id,
      trigger_message_id: trigger_message_id,
      kind: kind,
      reminder_id: reminder_id
    }.compact
  end

  def initialize(message)
    @message = message
    @conversation = message.conversation
  end

  # Commit a claim before provider I/O. An unresolved claim is not retryable
  # without a receipt read-back: a timeout can mean the provider accepted it.
  def perform(&)
    unless claim_pending_delivery!
      reconcile_pending_ack!
      # A failed enqueue after a committed deferral retries this job. Restore
      # its schedule without attempting external delivery before next_at.
      enqueue_deferred_retry! if deferred_delivery?
      return
    end

    result = Timeout.timeout(PROVIDER_DISPATCH_DEADLINE, &)
    state = finalize_delivery!(result)
    reconcile_pending_ack!
  rescue StandardError => e
    # An exception before the claim is committed did not touch the provider.
    # Let Sidekiq retry instead of swallowing a transient DB/lookup failure.
    raise unless @message.reload.additional_attributes.to_h[STATE_KEY] == 'dispatching'

    # The provider id survives a Ruby exception after the TikTok POST too,
    # not only a worker crash. Recover through the contact/conversation fence
    # and reconcile outside it instead of overwriting the accepted receipt.
    if @message.source_id.present? && @conversation.inbox.channel_type == 'Channel::Tiktok'
      claim_pending_delivery!
      reconcile_pending_ack!
      return
    end

    @conversation.with_captain_control_lock do
      @message.reload
      mark_delivery!('outcome_unknown', error_class: e.class.name, failed: true) if delivery_state == 'dispatching'
    end
    Rails.logger.error("[CAPTAIN][Delivery] outcome unknown message_id=#{@message.id} error_class=#{e.class.name}")
  else
    # The Cloud provider persists next_at while this claim is dispatching.
    # Enqueue only after the deferred state commits, never inside provider I/O.
    enqueue_deferred_retry! if state == 'deferred'
  end

  private

  def finalize_delivery!(result)
    @conversation.with_captain_control_lock do
      @message.reload
      @conversation.reload
      state = delivery_result_state(result)
      ack = if state == 'submitted' && result == :delivered
              { 'status' => 'delivered' }
            elsif state == 'provider_failed'
              { 'status' => 'failed', 'error' => result.last }
            end
      mark_delivery!(state, receipt_id: @message.source_id, failed: %w[submitted deferred].exclude?(state), ack: ack)
      state
    end
  end

  def reconcile_pending_ack!
    Captain::Conversation::DeliveryAcknowledgementService.new(@message).perform
  end

  def deferred_delivery?
    @message.reload
    return false unless delivery_state == 'deferred' && Whatsapp::Providers::WhatsappCloudService.transient_send_retry_scheduled?(@message)

    @message.additional_attributes.to_h[RETRY_ENQUEUED_KEY] != deferred_retry_at
  end

  def enqueue_deferred_retry!
    return unless deferred_delivery?

    next_at = deferred_retry_at
    job = SendReplyJob.set(wait_until: Time.iso8601(next_at)).perform_later(@message.id)
    raise(job&.enqueue_error || ActiveJob::EnqueueError.new('Captain Cloud deferred retry was not enqueued')) unless job&.successfully_enqueued?

    @message.with_lock do
      if delivery_state == 'deferred' && deferred_retry_at == next_at
        @message.update_columns(additional_attributes: @message.additional_attributes.to_h.merge(RETRY_ENQUEUED_KEY => next_at)) # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end

  def deferred_retry_at
    @message.content_attributes.to_h.deep_stringify_keys['whatsapp_cloud_send_retry_next_at']
  end

  def delivery_result_state(result)
    case result
    when Array then result.first == :provider_failed ? 'provider_failed' : 'outcome_unknown'
    when :unsupported then 'unsupported'
    when :outcome_unknown then 'outcome_unknown'
    when :deferred then stale? ? 'cancelled' : 'deferred'
    else stale? ? 'outcome_unknown' : 'submitted'
    end
  end

  def claim_pending_delivery!
    Message.transaction do
      # Serialize with incoming and human messages even before their channel
      # conversation has been linked to the shared Thread.
      Conversations::CommunicationThreadResolver.lock_contact_thread!(@conversation.account_id, @conversation.contact_id)
      @conversation.with_captain_control_lock do
        @message.reload
        @conversation.reload
        next false unless @message.outgoing? && !@message.private?

        # TikTok persists its accepted provider id before fence finalization.
        # A worker may die after that write, leaving a dispatching claim. The
        # receipt proves acceptance; commit its ack before releasing the fence.
        if delivery_state == 'dispatching' && @message.source_id.present? && @conversation.inbox.channel_type == 'Channel::Tiktok'
          if stale?
            mark_delivery!('outcome_unknown', receipt_id: @message.source_id, failed: true)
          else
            mark_delivery!('submitted', receipt_id: @message.source_id, ack: { 'status' => 'delivered' })
          end
          next false
        end

        next false unless retryable_delivery_state?

        if @message.source_id.present?
          ack = { 'status' => 'delivered' } if @conversation.inbox.channel_type == 'Channel::Tiktok' && !stale?
          mark_delivery!('submitted', receipt_id: @message.source_id, ack: ack)
          next false
        end

        if stale?
          mark_delivery!('cancelled', failed: true)
          next false
        end

        mark_delivery!('dispatching', claimed_at: Time.current.iso8601(6))
        true
      end
    end
  end

  def stale? # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    attributes = @message.additional_attributes.to_h
    # No persisted trigger/control snapshot means a legacy public Captain
    # reply cannot be ordered against incoming commits (message IDs are only
    # allocation order). Do not infer safety from timestamps or handoff state.
    return true unless attributes.key?(FENCE_KEY)

    fence = attributes[FENCE_KEY].to_h.with_indifferent_access
    return true unless fence[:control_generation].present? && fence[:trigger_message_id].present? && fence[:assistant_id].present?
    return true unless fence[:assistant_id].to_i == @message.sender_id
    return true unless fence[:kind] == 'reminder' || @conversation.inbox.captain_assistant&.id == fence[:assistant_id].to_i
    return true unless @conversation.current_captain_control_generation.to_i == fence[:control_generation].to_i
    return true if Captain::Conversation::ControlService.human_response_after?(@conversation, fence[:trigger_message_id])

    case fence[:kind]
    when 'reply' then stale_reply?(attributes, fence)
    when 'follow_up' then stale_follow_up?(attributes, fence)
    when 'handoff' then !@conversation.captain_human_control_active? || later_contact_incoming?(fence)
    when 'resolution' then stale_resolution?(fence)
    when 'reminder' then stale_reminder?(attributes, fence)
    else true
    end
  end

  def stale_reply?(attributes, fence) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    trigger_id = fence[:trigger_message_id].to_i
    follow_up = attributes['captain_follow_up'].present?
    return true if trigger_id <= 0 || @conversation.captain_human_control_active?

    can_reply_when_open = follow_up || @conversation.inbox.captain_inbox&.reply_to_open_conversations?
    return true unless @conversation.pending? || (@conversation.open? && can_reply_when_open)

    conversations = Conversation.where(account_id: @conversation.account_id, contact_id: @conversation.contact_id).select(:id)
    incoming = Message.where(account_id: @conversation.account_id, conversation_id: conversations).incoming
    return true if incoming.exists?(['messages.id > ?', trigger_id])

    !follow_up && incoming.reorder(created_at: :desc, id: :desc).pick(:id).to_i != trigger_id
  end

  def stale_resolution?(fence)
    !(@conversation.captain_ai_control_active? && @conversation.resolved?) || later_contact_incoming?(fence)
  end

  def later_contact_incoming?(fence)
    Captain::Conversation::ControlService.contact_messages_scope(@conversation).incoming
                                         .exists?(['messages.id > ?', fence[:trigger_message_id].to_i])
  end

  def stale_follow_up?(attributes, fence)
    marker = attributes['captain_follow_up'].to_h
    return true unless marker['anchor_message_id'].to_i == fence[:trigger_message_id].to_i
    return true unless marker['assistant_id'].to_i == fence[:assistant_id].to_i
    return true unless @conversation.captain_ai_control_active?
    return true unless @conversation.messages.outgoing.exists?(id: fence[:trigger_message_id], sender: @message.sender)

    stale_reply?(attributes, fence)
  end

  def stale_reminder?(attributes, fence)
    reminder = Reminder.find_by(id: fence[:reminder_id], account_id: @message.account_id)
    return true unless valid_reminder_source?(reminder, attributes, fence)
    return true if @conversation.captain_human_control_active?

    later_contact_incoming?(fence)
  end

  def valid_reminder_source?(reminder, attributes, fence)
    return false unless captain_reminder?(reminder)
    return false unless reminder.delivery_materialized_for?(@message.id)
    return false unless attributes['touch_id'].to_s == reminder.id.to_s
    return false unless [reminder.target_conversation_id, reminder.conversation_id].include?(@conversation.id)

    configured_assistant_id = reminder.metadata.to_h['captain_assistant_id'].presence || @conversation.inbox.captain_assistant&.id
    configured_assistant_id.to_i == fence[:assistant_id].to_i
  end

  def captain_reminder?(reminder)
    reminder&.ai_agent_wakeup? || (reminder&.send_message? && reminder.agent?)
  end

  def delivery_state
    @message.additional_attributes.to_h[STATE_KEY]
  end

  def retryable_delivery_state?
    return true if delivery_state.blank?
    return false unless delivery_state == 'deferred'
    return false unless Whatsapp::Providers::WhatsappCloudService.transient_send_retry_scheduled?(@message)

    next_at = @message.content_attributes.to_h.deep_stringify_keys['whatsapp_cloud_send_retry_next_at']
    next_at.present? && Time.iso8601(next_at) <= Time.current
  end

  def mark_delivery!(state, receipt_id: nil, error_class: nil, failed: false, claimed_at: nil, ack: nil)
    attributes = @message.additional_attributes.to_h.merge(
      STATE_KEY => state,
      'captain_delivery_receipt_id' => receipt_id,
      'captain_delivery_error_class' => error_class,
      'captain_delivery_claimed_at' => claimed_at || @message.additional_attributes.to_h['captain_delivery_claimed_at']
    ).compact
    attributes[PENDING_ACK_KEY] = ack if ack
    columns = { additional_attributes: attributes }
    columns[:status] = Message.statuses[:failed] if failed
    @message.update_columns(columns.merge(updated_at: Time.current)) # rubocop:disable Rails/SkipsModelValidations
  end
end
