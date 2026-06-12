# frozen_string_literal: true

class Telephony::VirtualPbx::RemoteProvisioner
  FEATURE_FLAG = 'TELEPHONY_VIRTUAL_PBX_REMOTE_COMMIT_ENABLED'

  def initialize(account:, current_user:, resource_client: nil, reconciler: nil)
    @account = account
    @current_user = current_user
    @resource_client = resource_client
    @reconciler = reconciler
  end

  def execute(operation:, desired_state:, plan:, remote_commit: false)
    run = Telephony::ProvisioningRun.build_for(
      account: account,
      operation: operation,
      desired_state: desired_state,
      plan: plan,
      current_user: current_user,
      remote_commit: remote_commit,
      status: 'pending'
    )
    run.save!

    unless ActiveModel::Type::Boolean.new.cast(remote_commit)
      return block_run!(run, code: 'REMOTE_COMMIT_NOT_REQUESTED', message: 'Remote commit was not requested')
    end

    unless remote_commit_enabled?
      return block_run!(run, code: 'REMOTE_MUTATION_REQUIRES_APPROVAL', message: 'Remote provisioning is disabled by configuration')
    end

    operations = Array.wrap(plan[:operations] || plan['operations'])
    if operations.any? { |item| item.with_indifferent_access[:risk] == 'blocked' }
      return block_run!(run, code: 'REMOTE_PLAN_BLOCKED', message: 'Provisioning plan contains blocked operations')
    end

    run.mark_running!
    executed_operations = []
    client = resource_client_for(run, desired_state)

    operations.each do |operation_payload|
      operation_attrs = operation_payload.with_indifferent_access
      result = client.dispatch(operation_attrs)
      executed_operations << operation_attrs.slice(:key, :method, :path).merge(status: 'succeeded', result: sanitize_result(result))
    end

    reconciliation = reconciler_for(client).check(desired_state)
    unless reconciliation[:ready]
      error = Telephony::Error.new(
        code: 'REMOTE_RECONCILE_FAILED',
        message: 'Remote resources did not match OneLink desired state after provisioning',
        status: :bad_gateway,
        details: { drift: reconciliation[:drift], errors: reconciliation[:errors] }.compact
      )
      run.mark_failed!(error: error, executed_operations: executed_operations)
      return result_payload(
        run,
        status: reconciliation[:status] || 'failed',
        remote_commit: true,
        executed_operations: executed_operations,
        reconciliation: reconciliation,
        errors: [error_payload(error)]
      )
    end

    run.mark_succeeded!(executed_operations: executed_operations, remote_snapshot: reconciliation[:remote_snapshot] || {})
    mark_local_synced!(desired_state)

    result_payload(
      run,
      status: 'succeeded',
      remote_commit: true,
      executed_operations: executed_operations,
      reconciliation: reconciliation
    )
  rescue Telephony::Error => e
    run&.mark_failed!(error: e, executed_operations: executed_operations || [])
    mark_local_failed!(desired_state, e)
    result_payload(run, status: 'failed', remote_commit: run&.remote_commit || false, errors: [error_payload(e)])
  end

  private

  attr_reader :account, :current_user, :resource_client, :reconciler

  def block_run!(run, code:, message:)
    run.mark_blocked!(code: code, message: message)
    result_payload(run, status: 'blocked', remote_commit: false, errors: [{ code: code, message: message }])
  end

  def result_payload(run, status:, remote_commit:, executed_operations: [], errors: [], reconciliation: nil)
    {
      status: status,
      remote_commit: remote_commit,
      provisioning_run: run.summary_payload,
      executed_operations: executed_operations,
      reconciliation: reconciliation,
      errors: errors
    }.compact
  end

  def resource_client_for(run, desired_state)
    resource_client || Telephony::VirtualPbx::BridgeResourceClient.new(
      bridge_client: Telephony::BridgeClient.new(account_id: account.id),
      idempotency_key: Telephony::ProvisioningRun.remote_idempotency_key_for(operation: run.operation, desired_state: desired_state)
    )
  end

  def reconciler_for(client)
    reconciler || Telephony::VirtualPbx::Reconciler.new(account: account, resource_client: client)
  end

  def remote_commit_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(FEATURE_FLAG, nil))
  end

  def mark_local_synced!(desired_state)
    state = desired_state.with_indifferent_access
    attrs = { provisioning_status: 'fonoster_synced', last_synced_at: Time.current, remote_drift_detected_at: nil, remote_drift_summary: {} }
    update_if_columns_exist(Telephony::NumberBinding, state.dig(:resources, :number_binding_id), attrs)
    update_if_columns_exist(Telephony::ProviderConnection, state.dig(:resources, :provider_connection_id), attrs.except(:last_synced_at))
  end

  def mark_local_failed!(desired_state, error)
    state = desired_state.to_h.with_indifferent_access
    attrs = {
      provisioning_status: 'remote_failed',
      remote_drift_detected_at: Time.current,
      remote_drift_summary: { code: error.code, message: error.message }
    }
    update_if_columns_exist(Telephony::NumberBinding, state.dig(:resources, :number_binding_id), attrs)
    update_if_columns_exist(Telephony::ProviderConnection, state.dig(:resources, :provider_connection_id), attrs)
  end

  def update_if_columns_exist(model, id, attrs)
    return if id.blank?

    record = model.find_by(id: id)
    return if record.blank?

    supported_attrs = attrs.stringify_keys.slice(*model.column_names)
    record.update_columns(supported_attrs.merge('updated_at' => Time.current)) if supported_attrs.present?
  end

  def sanitize_result(result)
    Telephony::VirtualPbx::BridgeResourceClient.sanitize_payload(result || {})
  end

  def error_payload(error)
    { code: error.code, message: error.message }
  end
end
