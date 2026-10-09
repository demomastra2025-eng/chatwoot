# frozen_string_literal: true

class Conversations::DeletionJob < ApplicationJob
  queue_as :low
  # Enroll the durable receipt and queue work before the request transaction
  # commits. An early worker retries until the receipt becomes visible.
  self.enqueue_after_transaction_commit = :never
  TRANSIENT_ERRORS = [
    ActiveRecord::Deadlocked, ActiveRecord::SerializationFailure,
    ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionTimeoutError,
    ActiveRecord::LockWaitTimeout
  ].freeze

  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, _error|
    next unless job.arguments.first.is_a?(Integer) && job.arguments.first.positive? && job.arguments.first <= Conversations::DeletionService::MAX_ID

    run = BulkActionRun.find_by(id: job.arguments.first)
    next unless run && run.resource_type == 'Conversation' && run.action_name == 'delete' &&
                run.metadata['operation_kind'] == Conversations::DeletionService::KIND

    run.with_lock do
      run.metadata.fetch('targets').each do |target|
        Conversations::DeletionService.record_target!(run, target['record_id'], status: 'failed', error_code: 'worker_failed')
        Conversations::DeletionService.record_cleanup!(run, target['record_id'], status: 'failed', warning_code: 'cleanup_failed')
      end
    end
  end

  def perform(run_id, ip = nil)
    run = BulkActionRun.find_by!(id: Conversations::DeletionService.identity(run_id))
    return unless valid_run?(run)

    run.with_lock do
      run.update!(status: :processing, started_at: run.started_at || Time.current) unless run.completed? || run.failed?
    end
    run.metadata.fetch('targets').each do |target|
      delete_target(run, target, ip)
      cleanup_target(run, target)
    end
  end

  private

  def valid_run?(run)
    run && run.resource_type == 'Conversation' && run.action_name == 'delete' &&
      run.metadata['operation_kind'] == Conversations::DeletionService::KIND
  end

  def delete_target(run, target, ip)
    object = nil
    deletion_context = nil
    deletion = DeleteObjectJob.new
    run.with_lock do
      current = run.metadata.fetch('targets').find { |entry| entry['record_id'] == target['record_id'] }
      next unless current && current['status'] == 'pending'

      object = authorized_target(run, current)
      if object.nil?
        cleanup = (current['routing'] || {}).merge('communication_thread_ids' => [])
        Conversations::DeletionService.record_target!(run, current['record_id'], status: 'deleted', cleanup_context: cleanup)
        next
      end
      deletion.destroy_tracked_conversation(object) do |prepared_context|
        deletion_context = prepared_context
        Conversations::DeletionService.record_target!(run, current['record_id'], status: 'deleted', cleanup_context: prepared_context)
      end
    end
    deletion.finish_tracked_conversation(object, run.user, ip, deletion_context) if object && deletion_context
  rescue StandardError => error
    record_failure(run, target, error)
  end

  def authorized_target(run, current)
    membership = run.account.account_users.find_by(user_id: run.user_id)
    context = { account: run.account, user: run.user, account_user: membership }
    raise Pundit::NotAuthorizedError unless membership && ConversationPolicy.new(context, Conversation).destroy?

    object = run.account.conversations.lock.find_by(id: current['record_id'])
    return unless object

    raise Conversations::DeletionService::InvalidRequest unless object.display_id == current['conversation_id']
    policy = ConversationPolicy.new(context, object)
    raise Pundit::NotAuthorizedError unless policy.show? && policy.destroy?

    thread_id = run.metadata.fetch('selection')['thread_id']
    if thread_id
      thread = run.account.communication_threads.find_by(display_id: thread_id)
      raise Conversations::DeletionService::InvalidRequest unless thread&.communication_thread_conversations&.exists?(conversation_id: object.id)
    end
    object
  end

  def record_failure(run, target, error)
    run.reload
    current = run.metadata.fetch('targets').find { |entry| entry['record_id'] == target['record_id'] }
    raise error if current && current['status'] == 'pending' && TRANSIENT_ERRORS.any? { |type| error.is_a?(type) }

    run.with_lock do
      current = run.metadata.fetch('targets').find { |entry| entry['record_id'] == target['record_id'] }
      if current && current['status'] == 'deleted'
        Conversations::DeletionService.record_target!(run, target['record_id'], status: 'deleted', warning_code: 'audit_failed')
      else
        code = error.is_a?(Pundit::NotAuthorizedError) ? 'permission_changed' : 'destroy_failed'
        Conversations::DeletionService.record_target!(run, target['record_id'], status: 'failed', error_code: code)
      end
    end
    Rails.logger.warn("[Conversation deletion] run=#{run.id} target=#{target['record_id']} error=#{error.class.name}")
  end

  def cleanup_target(run, target)
    run.with_lock do
      current = run.metadata.fetch('targets').find { |entry| entry['record_id'] == target['record_id'] }
      next unless current && current['status'] == 'deleted' && current.dig('cleanup', 'status') == 'pending'

      broadcast_deleted(run, current)
      DeleteObjectJob.new.cleanup_tracked_conversation(run.account, current['cleanup'].fetch('communication_thread_ids', []))
      Conversations::DeletionService.record_cleanup!(run, current['record_id'], status: 'completed')
    end
  rescue StandardError => error
    run.reload
    run.with_lock do
      Conversations::DeletionService.record_target!(run, target['record_id'], status: 'deleted', warning_code: 'cleanup_pending')
    end
    raise error
  end

  def broadcast_deleted(run, target)
    routing = target.fetch('cleanup').slice('inbox_id', 'team_id', 'assignee_id')
    conversation = Conversation.new(routing.merge('id' => target['record_id'], 'account_id' => run.account_id))
    members = run.account.account_users.includes(:user, :custom_role).filter_map do |membership|
      user = membership.user
      context = { account: run.account, user: user, account_user: membership }
      user.pubsub_token if ConversationPolicy.new(context, conversation).show?
    end
    ActionCableBroadcastJob.perform_now(members, Events::Types::CONVERSATION_DELETED,
                                       { account_id: run.account_id, id: target['conversation_id'] })
  end
end
