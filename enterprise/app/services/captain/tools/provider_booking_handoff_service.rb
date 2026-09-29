class Captain::Tools::ProviderBookingHandoffService
  FENCE_KEY = 'ai_booking_response_fence'.freeze
  STAFF_NOTE_ID_KEY = Integrations::Medelement::AiBookingOutcomeJob::STAFF_NOTE_ID_KEY
  FENCE_KEYS = %w[control_generation status_transition_id last_message_id].freeze

  # rubocop:disable Metrics/ParameterLists
  def initialize(assistant:, conversation:, appointment: nil, command: nil, fence: nil, orphaned_write: false)
    @assistant = assistant
    @conversation = conversation
    @appointment = appointment
    @command = command
    @fence = fence
    @orphaned_write = orphaned_write
  end
  # rubocop:enable Metrics/ParameterLists

  # Booking failures are a system-authorized handoff, not a model-generated
  # handoff request. The control fence prevents a late provider outcome from
  # reopening a conversation after a human or a newer Captain run took over.
  def perform
    return :invalid_context unless valid_context?
    return :missing_fence if response_fence.blank?

    command ? command.with_lock { handoff_current_booking! } : handoff_current_booking!
  end

  def self.capture_fence!(command:, fence:)
    values = fence.to_h.stringify_keys.slice(*FENCE_KEYS)
    return if values['control_generation'].nil? || values['last_message_id'].blank?

    command.with_lock do
      state = command.execution_state.to_h
      next if state[FENCE_KEY].present?

      command.update!(execution_state: state.merge(FENCE_KEY => values))
    end
  end

  private

  attr_reader :assistant, :conversation, :appointment, :command, :fence, :orphaned_write

  def valid_context?
    return false unless assistant_allowed?
    return false unless booking_matches_context?
    return true unless command

    command_matches_context?
  end

  def booking_matches_context?
    return orphaned_write_context? if orphaned_write

    appointment.nil? || appointment_matches_context?
  end

  def assistant_allowed?
    assistant&.usage_mode == 'external_agent' && conversation&.account_id == assistant.account_id &&
      CaptainInbox.exists?(inbox_id: conversation.inbox_id, captain_assistant_id: assistant.id)
  end

  def appointment_matches_context?
    appointment.account_id == assistant.account_id && appointment.conversation_id == conversation.id &&
      appointment.contact_id == conversation.contact_id
  end

  def command_matches_context?
    appointment && handoff_operation? && command.account_id == assistant.account_id &&
      command.appointment_id == appointment.id && command.contact_id == (orphaned_write ? conversation.contact_id : appointment.contact_id) &&
      command_actor_matches_context?
  end

  # A failed or unknown AI reschedule (move_reception) gets the same handoff as a
  # failed create; orphaned writes only exist for creates.
  def handoff_operation?
    command.create_reception? || (command.move_reception? && !orphaned_write)
  end

  def orphaned_write_context?
    return false unless command&.create_reception? && appointment&.account_id == assistant.account_id
    return false unless Captain::Tools::ProviderBookingOutcomeService.write_receipt?(command)

    original_snapshot_matches_context?
  end

  def original_snapshot_matches_context?
    snapshot = command.request_snapshot
    snapshot['account_id'] == command.account_id && snapshot['appointment_id'] == appointment.id &&
      snapshot['contact_id'] == conversation.contact_id && snapshot['conversation_id'].to_s == conversation.id.to_s
  end

  def command_actor_matches_context?
    command.request_snapshot.dig('actor', 'type') == 'Captain::Assistant' &&
      command.request_snapshot.dig('actor', 'id').to_s == assistant.id.to_s &&
      command.request_snapshot['conversation_id'].to_s == conversation.id.to_s
  end

  def response_fence
    return @response_fence if defined?(@response_fence)

    values = (fence.presence || command&.execution_state.to_h&.dig(FENCE_KEY)).to_h.stringify_keys.slice(*FENCE_KEYS)
    @response_fence = values['control_generation'].nil? || values['last_message_id'].blank? ? {} : values
  end

  def handoff_current_booking!
    return handoff! if orphaned_write

    if command
      appointment.with_lock do
        next :stale_booking unless Integrations::Medelement::AppointmentProviderStatus.bound_to_command?(appointment, command)

        handoff!
      end
    else
      handoff!
    end
  end

  def handoff!
    note = nil
    result = conversation.bot_handoff!(source: 'system', actor: assistant, fence: response_fence) do
      note = existing_staff_note || create_staff_note!
    end
    if result.in?([:stale, :already_applied])
      conversation.with_lock do
        conversation.with_captain_control_lock do
          note = existing_staff_note || create_staff_note! if original_human_takeover?
        end
      end
    end
    record_note!(note) if note && command
    result
  end

  # The fenced conversation was taken over by a human of the original run when
  # the control generation is unchanged and the conversation is human-owned, or
  # the generation moved only through human takeovers: no release back to
  # Captain happened in the communication thread after the fence, and the
  # conversation left pending after the fence (an agent reply, a handoff by the
  # tool, a newer run of the same pending episode or the agent API, an existing
  # assignment) or a public human reply anywhere in the thread followed the
  # fence message. Every staff public reply moves the thread generation again
  # while any Captain channel of the thread is still pending, so one takeover
  # can move it by more than one step. A public reply in a non-Captain sibling
  # channel leaves this conversation pending; it gets the note without
  # reopening. A release starts a newer Captain run, which never gets a late
  # note. Without a status epoch in the fence a release cannot be ruled out, so
  # only a single step counts. The legacy captain_control_state column is only
  # mirrored for the previous release image and is not read.
  def original_human_takeover?
    generation = conversation.current_captain_control_generation.to_i
    expected = response_fence['control_generation'].to_i
    return conversation.captain_human_control_active? if generation == expected
    return false unless takeover_steps?(generation - expected)
    return false if releases_after_fence.exists?

    left_pending_after_fence? ||
      Captain::Conversation::ControlService.human_response_after?(conversation, response_fence['last_message_id'])
  end

  def takeover_steps?(steps)
    steps == 1 || (steps > 1 && status_epoch?)
  end

  def left_pending_after_fence?
    conversation.captain_human_control_active? && status_transitions_after_fence.exists?(from_status: 'pending')
  end

  # A release back to Captain is a transition of this conversation to pending
  # from any source, which starts a newer Captain run, or an explicit staff
  # release in any channel of the thread: the same actor and source rule as
  # Conversations::StatusTransitionService#explicit_captain_control_release?,
  # to pending or resolved from a human-owned status, which moves the
  # generation (ControlService#prepare_ai!). Auto-resolve, macro, automation,
  # contact and reminder resolves leave the thread human-owned.
  def releases_after_fence
    return ConversationStatusTransition.none unless status_epoch?

    own = ConversationStatusTransition.where(conversation_id: conversation.id, id: (response_fence['status_transition_id'].to_i + 1)..)
    transitions = conversation.communication_thread ? own.or(sibling_status_transitions_after_fence) : own
    own.where(to_status: 'pending').or(explicit_captain_control_releases(transitions))
  end

  def explicit_captain_control_releases(transitions)
    transitions.where(
      source: Conversations::StatusTransitionService::CAPTAIN_CONTROL_RELEASE_SOURCES,
      to_status: Conversations::StatusTransitionService::CAPTAIN_CONTROL_RELEASE_STATUSES
    ).where.not(actor_id: nil).where.not(from_status: 'pending')
  end

  # Transition ids are global, so this conversation's status epoch cannot fence
  # a sibling transition; sibling transitions count from the fence message on,
  # or all of them when that message is gone.
  def sibling_status_transitions_after_fence
    siblings = conversation.communication_thread.conversations.where(account_id: conversation.account_id).where.not(id: conversation.id)
    transitions = ConversationStatusTransition.where(account_id: conversation.account_id, conversation_id: siblings.select(:id))
    fence_message_created_at = Message.where(account_id: conversation.account_id, id: response_fence['last_message_id']).pick(:created_at)
    fence_message_created_at ? transitions.where(created_at: fence_message_created_at..) : transitions
  end

  def status_epoch?
    fence_transition_id = response_fence['status_transition_id']
    !fence_transition_id.nil? && !fence_transition_id.to_i.negative?
  end

  # Without a status epoch in the fence there is no transition evidence.
  def status_transitions_after_fence
    return conversation.status_transitions.none unless status_epoch?

    conversation.status_transitions.where(id: (response_fence['status_transition_id'].to_i + 1)..)
  end

  def existing_staff_note
    scope = conversation.messages.outgoing.where(private: true)
    if command
      scope.where("additional_attributes ->> 'medelement_provider_command_id' = ?", command.id.to_s).first
    else
      scope.where("additional_attributes ->> 'medelement_booking_handoff_message_id' = ?", response_fence['last_message_id'].to_s).first
    end
  end

  def create_staff_note!
    conversation.messages.create!(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      private: true,
      sender: assistant,
      content: I18n.with_locale(assistant.account.locale) { I18n.t('conversations.captain.ai_booking_handoff_needs_review') },
      additional_attributes: {
        medelement_provider_command_id: command&.id,
        scheduling_appointment_id: appointment&.id,
        medelement_booking_handoff_message_id: response_fence['last_message_id']
      }.compact
    )
  end

  def record_note!(note)
    state = command.execution_state.to_h.merge(STAFF_NOTE_ID_KEY => note.id)
    if orphaned_write && command.contact_id != appointment.contact_id
      # An acknowledged orphan still belongs to the original contact. The command
      # association validator rejects metadata updates after the local slot moves.
      # rubocop:disable Rails/SkipsModelValidations
      command.update_column(:execution_state, state)
      # rubocop:enable Rails/SkipsModelValidations
    else
      command.update!(execution_state: state)
    end
  end
end
