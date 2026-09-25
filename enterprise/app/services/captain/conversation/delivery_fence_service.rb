require 'timeout'

class Captain::Conversation::DeliveryFenceService
  FENCE_KEY = 'captain_delivery_fence'.freeze
  STATE_KEY = 'captain_delivery_state'.freeze
  # A provider may accept a request even if the local client times out. This
  # bounds the job, not the time an incoming message has to wait for a lock.
  PROVIDER_DISPATCH_DEADLINE = 8

  def initialize(message)
    @message = message
    @conversation = message.conversation
  end

  # The committed claim prevents a duplicate job from replaying a request after
  # an ambiguous timeout or a worker crash. An unresolved claim needs read-back
  # or manual reconciliation; it is never silently retried.
  def perform
    return unless claim_pending_delivery!

    # The claim was committed before the first byte could leave this worker.
    # No contact advisory lock or control-owner row lock crosses provider I/O:
    # takeover and incoming messages must not wait for an external endpoint.
    result = Timeout.timeout(PROVIDER_DISPATCH_DEADLINE) { yield }
    @conversation.with_captain_control_lock do
      @message.reload
      @conversation.reload
      state = case result
              when :unsupported then 'unsupported'
              when :outcome_unknown then 'outcome_unknown'
              else stale? ? 'outcome_unknown' : 'submitted'
              end
      # A request claimed before takeover may arrive afterwards. Its receipt
      # is kept for human reconciliation; it is never labelled cancelled.
      mark_delivery!(state, receipt_id: @message.source_id, failed: state != 'submitted')
    end
  rescue StandardError => e
    # A provider can accept a request and still time out locally. Do not retry
    # until its exact receipt has been checked; do not report it as cancelled.
    @conversation.with_captain_control_lock do
      @message.reload
      mark_delivery!('outcome_unknown', error_class: e.class.name, failed: true) if delivery_state == 'dispatching'
    end
    Rails.logger.error("[CAPTAIN][Delivery] outcome unknown message_id=#{@message.id} error_class=#{e.class.name}")
  end

  private

  def claim_pending_delivery!
    Message.transaction do
      # An incoming on another, not-yet-linked channel takes this same lock
      # before its insert; the claim and M2 commit have a single total order.
      Conversations::CommunicationThreadResolver.lock_contact_thread!(@conversation.account_id, @conversation.contact_id)
      @conversation.with_captain_control_lock do
        @message.reload
        @conversation.reload
        next false unless @message.outgoing? && !@message.private? && delivery_state.blank?

        if @message.source_id.present?
          mark_delivery!('submitted', receipt_id: @message.source_id)
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

  def stale?
    attributes = @message.additional_attributes.to_h
    # Legacy handoff notices are created after a committed handoff. An older
    # unfenced reply must not escape after manual human takeover, even without
    # an outgoing human message.
    return stale_legacy?(attributes) unless attributes.key?(FENCE_KEY)

    fence = attributes[FENCE_KEY].to_h.with_indifferent_access
    return true unless fence[:control_generation].present? && fence[:trigger_message_id].present? && fence[:assistant_id].present?
    return true unless fence[:assistant_id].to_i == @message.sender_id
    return true unless @conversation.inbox.captain_assistant&.id == fence[:assistant_id].to_i
    return true unless @conversation.current_captain_control_generation.to_i == fence[:control_generation].to_i
    return true if Captain::Conversation::ControlService.human_response_after?(@conversation, fence[:trigger_message_id])

    case fence[:kind]
    when 'reply' then stale_reply?(attributes, fence)
    when 'handoff' then !@conversation.captain_human_control_active?
    when 'resolution' then stale_resolution?(fence)
    else true
    end
  end

  def stale_reply?(attributes, fence)
    trigger_id = fence[:trigger_message_id].to_i
    follow_up = attributes['captain_follow_up'].present?
    return true if trigger_id <= 0 || @conversation.captain_human_control_active?
    return true unless @conversation.pending? || (@conversation.open? && (follow_up || @conversation.inbox.captain_inbox&.reply_to_open_conversations?))

    # An inbound on a second channel can commit before its after-commit
    # resolver has attached it to the Thread. Use the contact identity guarded
    # by the advisory lock, not only the current links.
    conversations = Conversation.where(account_id: @conversation.account_id, contact_id: @conversation.contact_id).select(:id)
    incoming = Message.where(account_id: @conversation.account_id, conversation_id: conversations).incoming
    # A follow-up is anchored to an outgoing message; an ordinary reply must
    # still target the latest incoming across all channels of this contact.
    return true if incoming.where('messages.id > ?', trigger_id).exists?

    !follow_up && incoming.reorder(created_at: :desc, id: :desc).pick(:id).to_i != trigger_id
  end

  def stale_resolution?(fence)
    return true unless @conversation.captain_ai_control_active? && @conversation.resolved?

    Captain::Conversation::ControlService.contact_messages_scope(@conversation).incoming
                                         .where('messages.id > ?', fence[:trigger_message_id].to_i).exists?
  end

  def stale_legacy?(attributes)
    return true if Captain::Conversation::ControlService.human_response_after?(@conversation, @message.id)
    # No generation was stored in old messages; after any ownership cycle we
    # cannot prove they belong to the current AI run, even if AI is active.
    return true if @conversation.captain_ai_control_active? && @conversation.current_captain_control_generation.to_i.positive?
    return false unless @conversation.captain_human_control_active?

    handoff_at = @conversation.current_captain_handoff_applied_at
    handoff_at.blank? || @message.created_at < handoff_at || attributes['captain_follow_up'].present?
  end

  def delivery_state
    @message.additional_attributes.to_h[STATE_KEY]
  end

  def mark_delivery!(state, receipt_id: nil, error_class: nil, failed: false, claimed_at: nil)
    attributes = @message.additional_attributes.to_h.merge(
      STATE_KEY => state,
      'captain_delivery_receipt_id' => receipt_id,
      'captain_delivery_error_class' => error_class,
      'captain_delivery_claimed_at' => claimed_at || @message.additional_attributes.to_h['captain_delivery_claimed_at']
    ).compact
    columns = { additional_attributes: attributes }
    columns[:status] = Message.statuses[:failed] if failed
    @message.update_columns(columns) # rubocop:disable Rails/SkipsModelValidations
  end
end
