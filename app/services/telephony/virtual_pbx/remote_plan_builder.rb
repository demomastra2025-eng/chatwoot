# frozen_string_literal: true

require 'cgi'

class Telephony::VirtualPbx::RemotePlanBuilder
  REMOTE_MUTATIONS_BLOCKED = 'blocked'
  REMOTE_MUTATIONS_REQUIRES_APPROVAL = 'requires_approval'

  def initialize(account:)
    @account = account
    @ownership_policy = Telephony::VirtualPbx::OwnershipPolicy.new(account: account)
  end

  def build(operation:, desired_state:, remote_actual: nil)
    state = desired_state.with_indifferent_access
    ownership = ownership_policy.check!(operation: operation, desired_state: state)
    operations = operations_for(operation, state, ownership)
    operations = apply_remote_actual_conflicts(operations, remote_actual) if remote_actual.present?

    {
      operation: operation,
      status: plan_status(operations, ownership),
      remote_mutations: REMOTE_MUTATIONS_BLOCKED,
      operations: operations,
      conflicts: operations.filter_map { |item| item[:conflict] },
      generated_at: Time.current
    }
  end

  private

  attr_reader :account, :ownership_policy

  def operations_for(operation, state, ownership)
    case operation.to_s
    when 'delete'
      delete_operations(state, ownership)
    when 'update', 'reconcile'
      update_operations(state, ownership)
    else
      create_operations(state, ownership)
    end
  end

  def create_operations(state, ownership)
    refs = state[:refs] || {}
    [
      operation_payload('upsert_credentials', 'PUT', path('credentials', refs[:credentials_ref]), 'Prepare provider access for this call profile', ownership,
                        payload: credentials_payload(state)),
      operation_payload('upsert_trunk', 'PUT', path('trunks', refs[:trunk_ref]), 'Prepare provider connection for inbound calls', ownership,
                        payload: trunk_payload(state)),
      operation_payload('upsert_number', 'PUT', path('numbers', refs[:number_ref]), 'Connect the business number to OneLink runtime', ownership,
                        payload: number_payload(state)),
      operation_payload('update_number_route', 'PATCH', "#{path('numbers', refs[:number_ref])}/route", 'Apply selected routing mode', ownership,
                        payload: route_payload(state)),
      *agent_operations(state, ownership)
    ].compact
  end

  def update_operations(state, ownership)
    refs = state[:refs] || {}
    [
      operation_payload('patch_trunk', 'PATCH', path('trunks', refs[:trunk_ref]), 'Sync provider connection metadata', ownership,
                        payload: trunk_payload(state)),
      operation_payload('patch_number', 'PATCH', path('numbers', refs[:number_ref]), 'Sync business number metadata', ownership,
                        payload: number_payload(state)),
      operation_payload('patch_number_route', 'PATCH', "#{path('numbers', refs[:number_ref])}/route", 'Sync routing mode', ownership,
                        payload: route_payload(state)),
      *agent_operations(state, ownership)
    ].compact
  end

  def delete_operations(state, ownership)
    refs = state[:refs] || {}
    [
      operation_payload('delete_number', 'DELETE', path('numbers', refs[:number_ref]), 'Delete owned inbound number', ownership),
      operation_payload('delete_trunk', 'DELETE', path('trunks', refs[:trunk_ref]), 'Delete owned provider connection only if exclusive', ownership),
      operation_payload('delete_credentials', 'DELETE', path('credentials', refs[:credentials_ref]),
                        'Delete owned provider access only if exclusive', ownership)
    ].compact
  end

  def agent_operations(state, ownership)
    Array.wrap(state[:profiles]).filter_map do |profile|
      attrs = profile.with_indifferent_access
      next if attrs[:agent_ref].blank?

      operation_payload(
        'upsert_agent',
        'PUT',
        path('agents', attrs[:agent_ref]),
        'Sync employee extension assignment',
        ownership,
        payload: {
          ref: attrs[:agent_ref],
          agent_aor: attrs[:agent_aor],
          enabled: attrs[:enabled],
          metadata: ownership_metadata(state).merge(onelink_user_id: attrs[:user_id], internal_extension: attrs[:internal_extension])
        }
      )
    end
  end

  def operation_payload(key, method, path, description, ownership, payload: {})
    return if path.blank?

    risk = ownership[:allowed] ? 'requires_approval' : 'blocked'
    {
      key: key,
      method: method,
      path: path,
      description: description,
      owned: ownership[:allowed],
      shared: false,
      risk: risk,
      payload: sanitized(payload),
      payload_preview: payload_preview_for(key, payload),
      conflict: ownership[:allowed] ? nil : ownership[:conflict]
    }.compact
  end

  def credentials_payload(state)
    refs = state[:refs] || {}
    connection = state[:connection] || {}
    {
      ref: refs[:credentials_ref],
      username: connection[:username],
      metadata: ownership_metadata(state).merge(provider_kind: state[:provider_kind])
    }.compact
  end

  def trunk_payload(state)
    refs = state[:refs] || {}
    connection = state[:connection] || {}
    {
      ref: refs[:trunk_ref],
      name: connection[:name] || state[:name],
      host: connection[:host],
      port: connection[:port],
      transport: connection[:transport],
      send_register: connection[:send_register],
      credential_ref: refs[:credentials_ref],
      metadata: ownership_metadata(state).merge(provider_kind: state[:provider_kind])
    }.compact
  end

  def number_payload(state)
    refs = state[:refs] || {}
    phone_numbers = state[:phone_numbers] || {}
    {
      ref: refs[:number_ref],
      tel_url: phone_numbers[:fonoster_tel_url],
      trunk_ref: refs[:trunk_ref],
      metadata: ownership_metadata(state).merge(
        display_phone_number: phone_numbers[:display_phone_number],
        provider_account_number: phone_numbers[:provider_account_number],
        ingress_number: phone_numbers[:ingress_number]
      ).compact
    }.compact
  end

  def route_payload(state)
    refs = state[:refs] || {}
    routing = state[:routing] || {}
    {
      mode: routing[:bridge_mode] || routing[:mode] || 'operator',
      app_ref: routing[:app_ref] || refs[:runtime_app_ref] || refs[:app_ref],
      metadata: ownership_metadata(state).merge(number_ref: refs[:number_ref])
    }.compact
  end

  def ownership_metadata(state)
    ownership = state[:ownership] || {}
    {
      managed_by: 'onelink',
      onelink_account_id: ownership[:onelink_account_id] || state[:account_id],
      onelink_inbox_id: ownership[:onelink_inbox_id] || state[:inbox_id],
      onelink_channel_id: ownership[:onelink_channel_id] || state[:channel_id],
      onelink_number_binding_id: ownership[:onelink_number_binding_id]
    }.compact
  end

  def payload_preview_for(key, payload)
    metadata = (payload[:metadata] || {}).with_indifferent_access
    {
      key: key,
      provider_kind: metadata[:provider_kind],
      display_phone_number: metadata[:display_phone_number],
      ingress_number: metadata[:ingress_number],
      remote_mutation: 'requires_approval'
    }.compact
  end

  def apply_remote_actual_conflicts(operations, remote_actual)
    operations.map do |operation|
      next operation if operation[:risk] == 'blocked'

      conflict = remote_actual_conflict_for(operation, remote_actual)
      conflict.present? ? operation.merge(risk: 'blocked', conflict: conflict) : operation
    end
  end

  def remote_actual_conflict_for(operation, remote_actual)
    actual = remote_actual.with_indifferent_access
    return if actual.blank?
    return unless operation[:key].to_s.include?('number')

    metadata = (actual.dig(:number, :metadata) || actual.dig('number', 'metadata') || {}).with_indifferent_access
    return if metadata[:managed_by].blank? || metadata[:managed_by] == 'onelink'

    'remote number exists but is not owned by OneLink'
  end

  def plan_status(operations, ownership)
    return 'requires_manual_reconcile' unless ownership[:allowed]
    return 'requires_manual_reconcile' if operations.any? { |operation| operation[:risk] == 'blocked' }

    'dry_run_valid'
  end

  def path(resource, ref)
    return if ref.blank?

    "/telephony/#{resource}/#{CGI.escape(ref.to_s)}"
  end

  def sanitized(payload)
    Telephony::VirtualPbx::BridgeResourceClient.sanitize_payload(payload)
  end
end
