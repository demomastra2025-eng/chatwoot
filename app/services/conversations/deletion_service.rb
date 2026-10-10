# frozen_string_literal: true

class Conversations::DeletionService
  KIND = 'conversation_deletion'.freeze
  MAX_TARGETS = 100
  MAX_ID = (2**53) - 1
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  class InvalidRequest < StandardError; end
  class KeyConflict < StandardError; end
  class OverlappingRequest < StandardError; end

  def initialize(account:, user:)
    @account = account
    @user = user
  end

  def self.identity(value)
    raise InvalidRequest unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A[0-9]+\z/))

    id = value.to_i
    raise InvalidRequest unless id.positive? && id <= MAX_ID

    id
  end

  def self.request_key(value)
    raise InvalidRequest unless value.is_a?(String) && value.match?(UUID)

    value.downcase
  end

  def recover(request_key:, conversation_ids:, thread_id: nil)
    ensure_permission!
    signature = signature_for(conversation_ids, thread_id)
    key = self.class.request_key(request_key)
    run = runs.where("metadata->>'request_key' = ?", key).first
    return unless run

    raise KeyConflict unless run.metadata['selection'] == signature

    run
  end

  def create(conversations:, request_key:, conversation_ids:, thread_id: nil, ip: nil)
    ensure_permission!
    signature = signature_for(conversation_ids, thread_id)
    key = self.class.request_key(request_key)
    run = nil
    @account.with_lock do
      run = recover(request_key: key, conversation_ids: conversation_ids, thread_id: thread_id)
      return run if run

      targets = targets_for(conversations, signature)
      ensure_no_overlap!(targets)

      run = runs.create!(
        total_count: targets.size,
        metadata: { 'operation_kind' => KIND, 'request_key' => key, 'selection' => signature, 'targets' => targets }
      )
      enqueue(run, ip)
    end
    run
  end

  def lookup(request_key)
    runs.where("metadata->>'request_key' = ?", self.class.request_key(request_key)).first!
  end

  def self.response(run)
    { operation_id: run.id, accepted_conversation_ids: run.metadata.fetch('selection').fetch('conversation_ids'), payload: progress(run) }
  end

  def self.progress(run)
    run.as_progress_json.merge(metadata: run.metadata.slice('operation_kind', 'request_key', 'selection').merge(
      'targets' => run.metadata.fetch('targets').map { |target| target.except('cleanup', 'routing') }
    ))
  end

  def self.record_target!(run, record_id, status:, error_code: nil, warning_code: nil, cleanup_context: nil)
    metadata = run.metadata.deep_dup
    target = metadata.fetch('targets').find { |entry| entry['record_id'] == record_id }
    return unless target
    return unless target['status'] == 'pending' || (warning_code && target['status'] == status)

    target['status'] = status
    target['error_code'] = error_code if error_code
    target['warning_code'] = warning_code if warning_code
    target['audit_warning_code'] = warning_code if warning_code == 'audit_failed'
    target['cleanup'] = cleanup_context.stringify_keys.merge('status' => 'pending') if cleanup_context
    run.update!(progress_attributes(run, metadata))
  end

  def self.record_cleanup!(run, record_id, status:, warning_code: nil)
    metadata = run.metadata.deep_dup
    target = metadata.fetch('targets').find { |entry| entry['record_id'] == record_id }
    return unless target && target['status'] == 'deleted' && target.dig('cleanup', 'status') == 'pending'

    target['cleanup']['status'] = status
    target['warning_code'] = warning_code if warning_code
    if status == 'completed' && target['warning_code'] == 'cleanup_pending'
      target.delete('warning_code')
      target['warning_code'] = target['audit_warning_code'] if target['audit_warning_code']
    end
    run.update!(metadata: metadata)
  end

  def self.progress_attributes(run, metadata)
    targets = metadata.fetch('targets')
    processed = targets.count { |entry| entry['status'] != 'pending' }
    failed = targets.count { |entry| entry['status'] == 'failed' }
    terminal = processed == targets.size
    {
      metadata: metadata, processed_count: processed, failed_count: failed,
      status: terminal ? (failed.positive? ? :failed : :completed) : :processing,
      completed_at: terminal ? (run.completed_at || Time.current) : nil,
      error_message: failed.positive? ? 'conversation_deletion_failed' : nil
    }
  end
  private_class_method :progress_attributes

  private

  def targets_for(conversations, signature)
    targets = conversations.sort_by(&:display_id).map do |conversation|
      raise InvalidRequest unless conversation.account_id == @account.id && signature['conversation_ids'].include?(conversation.display_id)

      { 'record_id' => conversation.id, 'conversation_id' => conversation.display_id, 'status' => 'pending',
        'routing' => { 'inbox_id' => conversation.inbox_id, 'team_id' => conversation.team_id, 'assignee_id' => conversation.assignee_id } }
    end
    raise InvalidRequest unless targets.map { |target| target['conversation_id'] } == signature['conversation_ids']

    targets
  end

  def ensure_no_overlap!(targets)
    pending = @account.bulk_action_runs.where(resource_type: 'Conversation', action_name: 'delete', status: [:queued, :processing])
                      .where("metadata->>'operation_kind' = ?", KIND)
    overlapping = targets.reduce(pending.none) do |scope, target|
      value = [{ record_id: target['record_id'], status: 'pending' }].to_json
      scope.or(pending.where("metadata->'targets' @> ?", value))
    end
    raise OverlappingRequest if overlapping.exists?
  end

  def runs
    @account.bulk_action_runs.where(user_id: @user.id, resource_type: 'Conversation', action_name: 'delete')
            .where("metadata->>'operation_kind' = ?", KIND)
  end

  def signature_for(conversation_ids, thread_id)
    raise InvalidRequest unless conversation_ids.is_a?(Array) && conversation_ids.size.between?(1, MAX_TARGETS)

    ids = conversation_ids.map { |id| self.class.identity(id) }.sort
    raise InvalidRequest unless ids.uniq.size == ids.size
    { 'conversation_ids' => ids, 'thread_id' => thread_id.nil? ? nil : self.class.identity(thread_id) }
  end

  def ensure_permission!
    membership = @account.account_users.find_by(user_id: @user.id)
    context = { account: @account, user: @user, account_user: membership }
    raise Pundit::NotAuthorizedError unless membership && ConversationPolicy.new(context, Conversation).destroy?
  end

  def enqueue(run, ip)
    job = Conversations::DeletionJob.perform_later(run.id, ip)
    raise ActiveJob::EnqueueError, 'Could not enqueue conversation deletion' unless job
  rescue StandardError
    run.with_lock do
      run.metadata.fetch('targets').each do |target|
        self.class.record_target!(run, target['record_id'], status: 'failed', error_code: 'enqueue_failed')
      end
    end
  end
end
