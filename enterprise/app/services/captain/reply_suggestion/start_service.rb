# frozen_string_literal: true

# Starts a reply suggestion: checks the preconditions, fixes the engine (the agent, or the old prompt when the account has no
# agent), reuses the run that is already active for this user and conversation, and queues the job. The HTTP request returns at
# once; the run happens in GenerateJob.
class Captain::ReplySuggestion::StartService
  Result = Struct.new(:http_status, :body)

  REJECTIONS = {
    disabled: :forbidden,
    quota_exceeded: :too_many_requests,
    api_key_missing: :unprocessable_content,
    no_active_agent: :unprocessable_content,
    no_routing_cards: :unprocessable_content,
    voice_channel_unsupported: :unprocessable_content,
    busy: :too_many_requests
  }.freeze
  VOICE_CHANNEL = 'Channel::Voice'

  pattr_initialize [:account!, :user!, :conversation!, :conversation_display_id!]

  def perform
    code = precondition_error
    return reject(code) if code

    id = Captain::ReplySuggestion::RequestStore.new_id
    holder = claim_active_lock(id)
    return reused(holder) if holder

    return release_and_reject(id, :busy) unless Captain::ReplySuggestion::RequestLocks.claim_account_slot(account.id, id)

    queue_run(id)
  end

  private

  def precondition_error
    code = task_service.start_error_code
    return code if code

    :voice_channel_unsupported if conversation.inbox&.channel_type == VOICE_CHANNEL
  end

  def task_service
    @task_service ||= Captain::ReplySuggestionService.new(
      account: account, conversation_display_id: conversation_display_id, user: user, conversation: conversation
    )
  end

  def reject(code)
    Captain::ReplySuggestion::OutcomeEvent.publish_unavailable(account: account, user: user, conversation: conversation, error_code: code)
    Result.new(REJECTIONS.fetch(code), error_body(code))
  end

  def error_body(code)
    { error: I18n.t("captain.reply_suggestion.errors.#{code}"), error_code: code.to_s }
  end

  def release_and_reject(id, code)
    Captain::ReplySuggestion::RequestLocks.release_active(account.id, user.id, conversation.id, id)
    reject(code)
  end

  # One active run per user and conversation. A lock whose run is over, gone (a lost job) or cancelled (the manager pressed
  # «Отменить»: that run only waits for its next checkpoint) is taken over once, with the account slot of that run: a cancelled run
  # that still finishes its last step must not keep the new one out of the account's cap. Returns the active record to reuse, or
  # nil when this request holds the lock.
  def claim_active_lock(id)
    2.times do
      holder = Captain::ReplySuggestion::RequestLocks.claim_active(account.id, user.id, conversation.id, id)
      return if holder.nil?

      existing = Captain::ReplySuggestion::RequestStore.fetch(holder)
      return existing if reusable?(existing)

      Captain::ReplySuggestion::RequestLocks.release_active(account.id, user.id, conversation.id, holder)
      Captain::ReplySuggestion::RequestLocks.release_account_slot(account.id, holder)
    end
    nil
  end

  def reusable?(record)
    record.present? && Captain::ReplySuggestion::RequestStore::ACTIVE_STATUSES.include?(record['status']) &&
      !Captain::ReplySuggestion::RequestStore.cancel_requested?(record['id'])
  end

  def reused(record)
    Result.new(:accepted, Captain::ReplySuggestion::StatePresenter.new(record, reused: true).as_json)
  end

  def queue_run(id)
    record = create_record(id)
    # The approval cards of this manager's earlier suggestions in the conversation go: the new suggestion prepares its own. Their
    # provisional sticky agent goes too («Повторить» over a draft or a notice is not a use of it): the confirmed one leads again.
    Captain::ReplySuggestion::ActionApprovalService.discard_superseded!(
      account_id: account.id, conversation_id: conversation.id, user_id: user.id, keep_request_id: id
    )
    Captain::ReplySuggestion::StickyAgent.withdraw_superseded!(conversation, user_id: user.id, keep_request_id: id)
    Captain::ReplySuggestion::GenerateJob.perform_later(id)
    Result.new(:accepted, Captain::ReplySuggestion::StatePresenter.new(record, reused: false).as_json)
  rescue StandardError
    Captain::ReplySuggestion::RequestLocks.release!(lock_owner(id))
    raise
  end

  def create_record(id)
    engine = task_service.suggestion_engine
    Captain::ReplySuggestion::RequestStore.create!(
      lock_owner(id).merge(
        'conversation_display_id' => conversation_display_id.to_i, 'engine' => engine[:engine],
        'based_on_message_id' => based_on_message_id, 'budget_seconds' => Captain::ReplySuggestion.budget_seconds(router: routed?(engine))
      )
    )
  end

  # The agent of the request is chosen by the router among two or more agents (and may be a council): the longer budget.
  def routed?(engine)
    return false unless engine[:engine] == 'agent'

    !Captain::AgentGraph.new(Captain::ChannelScope.for_conversation(conversation)).solo?
  rescue StandardError
    false
  end

  # The fields of the request that its locks are kept under.
  def lock_owner(id)
    { 'id' => id, 'account_id' => account.id, 'user_id' => user.id, 'conversation_id' => conversation.id }
  end

  # The latest customer message of the person, in whichever conversation of the thread it came (see StatePresenter.stale?).
  def based_on_message_id
    Captain::ReplySuggestion::StatePresenter.customer_messages(conversation).maximum(:id)
  end
end
