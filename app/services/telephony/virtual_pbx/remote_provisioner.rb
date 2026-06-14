# frozen_string_literal: true

require 'cgi'

class Telephony::VirtualPbx::RemoteProvisioner
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

    operations = Array.wrap(plan[:operations] || plan['operations'])
    if operations.any? { |item| item.with_indifferent_access[:risk] == 'blocked' }
      return block_run!(run, code: 'REMOTE_PLAN_BLOCKED', message: 'Provisioning plan contains blocked operations')
    end

    run.mark_running!
    executed_operations = []
    client = resource_client_for(run, desired_state)
    effective_desired_state = desired_state.deep_dup.with_indifferent_access

    operations.each do |operation_payload|
      operation_attrs = operation_for_state(operation_payload.with_indifferent_access, effective_desired_state)
      result = client.dispatch(operation_attrs)
      apply_remote_result_to_state!(effective_desired_state, operation_attrs, result)
      executed_operations << operation_attrs.slice(:key, :method, :path).merge(status: 'succeeded', result: sanitize_result(result))
    end

    if operation.to_s == 'delete'
      run.mark_succeeded!(executed_operations: executed_operations, remote_snapshot: {})
      return result_payload(
        run,
        status: 'succeeded',
        remote_commit: true,
        executed_operations: executed_operations
      )
    end

    reconciliation = reconciler_for(client).check(effective_desired_state)
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
    mark_local_synced!(effective_desired_state)

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

  def mark_local_synced!(desired_state)
    state = desired_state.with_indifferent_access
    attrs = { provisioning_status: 'fonoster_synced', last_synced_at: Time.current, remote_drift_detected_at: nil, remote_drift_summary: {} }
    update_if_columns_exist(Telephony::NumberBinding, state.dig(:resources, :number_binding_id),
                            attrs.merge(number_ref: state.dig(:refs, :number_ref), trunk_ref: state.dig(:refs, :trunk_ref)).compact)
    update_if_columns_exist(Telephony::ProviderConnection, state.dig(:resources, :provider_connection_id),
                            attrs.merge(status: 'active', fonoster_trunk_ref: state.dig(:refs, :trunk_ref)).compact)
    update_sip_profile_refs!(state)
    update_channel_provider_config!(state)
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

  def operation_for_state(operation_attrs, desired_state)
    case operation_attrs[:key].to_s
    when 'update_number_route'
      return update_number_route_operation_for_state(operation_attrs, desired_state)
    when 'upsert_number'
      return number_operation_for_state(operation_attrs, desired_state)
    when 'upsert_connection_credentials'
      return operation_attrs.merge(payload: connection_credentials_payload(desired_state))
    when 'upsert_agent_credentials'
      return operation_attrs.merge(payload: profile_credentials_payload(operation_attrs, desired_state))
    when 'upsert_agent'
      return agent_operation_for_state(operation_attrs, desired_state)
    when 'upsert_sipuni_gateway'
      return sipuni_gateway_operation_for_state(operation_attrs, desired_state)
    end

    operation_attrs
  end

  def update_number_route_operation_for_state(operation_attrs, desired_state)
    number_ref = desired_state.dig(:refs, :number_ref)
    return operation_attrs if number_ref.blank?

    operation_attrs.merge(path: "/telephony/numbers/#{CGI.escape(number_ref.to_s)}/route")
  end

  def number_operation_for_state(operation_attrs, desired_state)
    refs = (desired_state[:refs] || {}).with_indifferent_access
    payload = (operation_attrs[:payload] || {}).with_indifferent_access
    payload[:ref] = refs[:number_ref] if refs[:number_ref].present?
    payload[:trunkRef] = refs[:trunk_ref] if refs[:trunk_ref].present?

    attrs = operation_attrs.merge(payload: payload)
    return attrs if refs[:number_ref].blank?

    attrs.merge(path: "/telephony/numbers/#{CGI.escape(refs[:number_ref].to_s)}")
  end

  def connection_credentials_payload(desired_state)
    state = desired_state.with_indifferent_access
    connection = (state[:connection] || {}).with_indifferent_access
    credentials_ref = connection[:credentials_ref].presence || state.dig(:refs, :credentials_ref)

    {
      ref: credentials_ref,
      name: connection[:name].presence || state[:name].presence || credentials_ref,
      username: connection[:username],
      password: connection[:password]
    }.compact
  end

  def profile_credentials_payload(operation_attrs, desired_state)
    credential_ref = operation_resource_ref(operation_attrs)
    profile = Array.wrap(desired_state[:profiles]).find do |candidate|
      candidate.with_indifferent_access[:credentials_ref].to_s == credential_ref.to_s
    end
    attrs = (profile || {}).with_indifferent_access

    {
      ref: credential_ref,
      name: profile_credentials_name(attrs, credential_ref),
      username: attrs[:sip_username],
      password: attrs[:sip_password],
      metadata: {
        managed_by: 'onelink',
        onelink_account_id: desired_state[:account_id],
        onelink_inbox_id: desired_state[:inbox_id],
        onelink_user_id: attrs[:user_id],
        internal_extension: attrs[:internal_extension]
      }.compact
    }.compact
  end

  def profile_credentials_name(attrs, credential_ref)
    [
      attrs[:user_name].presence,
      attrs[:internal_extension].presence
    ].compact.join(' ').presence || credential_ref
  end

  def agent_operation_for_state(operation_attrs, desired_state)
    agent_ref = operation_resource_ref(operation_attrs)
    profile = Array.wrap(desired_state[:profiles]).find do |candidate|
      attrs = candidate.with_indifferent_access
      attrs[:agent_ref].to_s == agent_ref.to_s || attrs[:fonoster_agent_ref].to_s == agent_ref.to_s
    end
    return operation_attrs if profile.blank?

    attrs = profile.with_indifferent_access
    credentials_ref = attrs[:fonoster_credentials_ref].presence || attrs[:credentials_ref].presence
    return operation_attrs if credentials_ref.blank?

    payload = (operation_attrs[:payload] || {}).with_indifferent_access
    operation_attrs.merge(payload: payload.merge(credentialsRef: credentials_ref))
  end

  def sipuni_gateway_operation_for_state(operation_attrs, desired_state)
    payload = (operation_attrs[:payload] || {}).with_indifferent_access
    provider_account_number = payload[:providerAccountNumber] || payload[:provider_account_number] || payload[:username]
    profile = Array.wrap(desired_state[:profiles]).find do |candidate|
      attrs = candidate.with_indifferent_access
      attrs[:sip_username].to_s == provider_account_number.to_s
    end
    return operation_attrs if profile.blank?

    attrs = profile.with_indifferent_access
    credentials_ref = attrs[:fonoster_credentials_ref].presence || attrs[:credentials_ref].presence
    return operation_attrs if credentials_ref.blank?

    operation_attrs.merge(payload: payload.merge(credentialsRef: credentials_ref))
  end

  def apply_remote_result_to_state!(desired_state, operation_attrs, result)
    remote_ref = (result || {}).with_indifferent_access[:ref]
    return if remote_ref.blank?

    case operation_attrs[:key].to_s
    when 'upsert_agent_credentials'
      apply_remote_profile_credentials_ref_to_state!(desired_state, operation_attrs, remote_ref)
    when 'upsert_trunk'
      desired_state[:refs] ||= {}
      desired_state[:refs][:trunk_ref] = remote_ref
      desired_state[:connection] ||= {}
      desired_state[:connection][:fonoster_trunk_ref] = remote_ref
    when 'upsert_number'
      desired_state[:refs] ||= {}
      desired_state[:refs][:number_ref] = remote_ref
    when 'upsert_agent'
      apply_remote_agent_ref_to_state!(desired_state, operation_attrs, remote_ref)
    end
  end

  def apply_remote_profile_credentials_ref_to_state!(desired_state, operation_attrs, remote_ref)
    previous_ref = operation_resource_ref(operation_attrs)
    Array.wrap(desired_state[:profiles]).each do |profile|
      attrs = profile.with_indifferent_access
      next unless attrs[:credentials_ref].to_s == previous_ref.to_s || attrs[:fonoster_credentials_ref].to_s == previous_ref.to_s

      profile[:credentials_ref] = remote_ref
      profile[:fonoster_credentials_ref] = remote_ref
    end
  end

  def apply_remote_agent_ref_to_state!(desired_state, operation_attrs, remote_ref)
    previous_ref = operation_resource_ref(operation_attrs)
    Array.wrap(desired_state[:profiles]).each do |profile|
      attrs = profile.with_indifferent_access
      next unless attrs[:agent_ref].to_s == previous_ref.to_s

      profile[:agent_ref] = remote_ref
      profile[:fonoster_agent_ref] = remote_ref
    end
  end

  def operation_resource_ref(operation_attrs)
    CGI.unescape(operation_attrs[:path].to_s.split('/').last.to_s)
  end

  def update_sip_profile_refs!(state)
    Array.wrap(state[:profiles]).each do |profile|
      attrs = profile.with_indifferent_access
      next if attrs[:id].blank?

      profile_attrs = { status: 'active', last_synced_at: Time.current }
      profile_attrs[:fonoster_agent_ref] = attrs[:fonoster_agent_ref] if attrs[:fonoster_agent_ref].present?

      credentials_ref = attrs[:fonoster_credentials_ref].presence || attrs[:credentials_ref].presence
      if credentials_ref.present?
        profile_attrs[:credentials_ref] = credentials_ref
        profile_attrs[:fonoster_credentials_ref] = credentials_ref
        profile_attrs[:password_secret_ref] = credentials_ref if attrs[:sip_password].present?
      end

      update_if_columns_exist(Telephony::SipProfile, attrs[:id], profile_attrs) if profile_attrs.present?
    end
  end

  def update_channel_provider_config!(state)
    channel_id = state.dig(:ownership, :onelink_channel_id) || state[:channel_id]
    return if channel_id.blank?

    channel = Channel::Voice.find_by(id: channel_id)
    return if channel.blank?

    provider_config = channel.provider_config_hash.with_indifferent_access
    provider_config[:number_ref] = state.dig(:refs, :number_ref) if state.dig(:refs, :number_ref).present?
    provider_config[:trunk_ref] = state.dig(:refs, :trunk_ref) if state.dig(:refs, :trunk_ref).present?
    channel.update_columns(provider_config: provider_config, updated_at: Time.current)
  end

  def error_payload(error)
    { code: error.code, message: error.message }
  end
end
