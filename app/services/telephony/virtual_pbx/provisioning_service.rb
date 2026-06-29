# frozen_string_literal: true

require 'cgi'

class Telephony::VirtualPbx::ProvisioningService
  ALLOWED_PROVIDER_KINDS = %w[asterisk_analog sipuni].freeze
  DEFAULT_ROUTE_MODE = 'operator'
  DEFAULT_FALLBACK_MODE = 'reject'
  DEFAULT_OPERATOR_DISTRIBUTION_MODE = Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_BROADCAST
  MANAGED_BY_ONELINK = 'onelink'
  LOCAL_OWNERSHIP_STATUS = 'local'
  REMOTE_MUTATION_REASON = 'REMOTE_MUTATION_REQUIRES_APPROVAL'
  DEFAULT_SIPUNI_TRUNK_REF = 'trunk-sipuni-onelink-out'
  DEFAULT_OPERATOR_SIP_DOMAIN = 'operator.cloud.vconsult.kz'
  PROVIDER_EXTENSION_MODES = %w[external_extension provider_extension].freeze

  def initialize(account:, current_user:, bridge_client: nil)
    @account = account
    @current_user = current_user
    @bridge_client = bridge_client
    @config_builder = Telephony::VirtualPbx::ConfigBuilder.new(account: account)
  end

  def show(inbox_id:, include_diagnostics: false)
    config = config_builder.for_inbox(inbox_id)
    product_payload(
      operation: 'show',
      config: config,
      include_diagnostics: include_diagnostics,
      extra: {
        remote_commit: false,
        mutation_allowed: false
      }
    )
  end

  def readiness_check(inbox_id:, include_diagnostics: false)
    config = config_builder.for_inbox(inbox_id)
    desired_state = desired_state_builder.for_inbox(inbox_id)
    plan = remote_plan_builder.build(operation: 'reconcile', desired_state: desired_state)

    product_payload(
      operation: 'readiness_check',
      config: config,
      include_diagnostics: include_diagnostics,
      extra: {
        remote_commit: false,
        mutation_allowed: false,
        ready: config[:ready] && plan[:status] != 'requires_manual_reconcile',
        provisioning_plan: product_plan(plan),
        warnings: config[:warnings]
      }
    )
  end

  def templates
    {
      operation: 'templates',
      remote_commit: false,
      mutation_allowed: false,
      provider_templates: Telephony::VirtualPbx::ConfigBuilder.provider_templates
    }
  end

  def status(inbox_id:, include_diagnostics: false)
    config = config_builder.for_inbox(inbox_id)

    product_payload(
      operation: 'status',
      config: config,
      include_diagnostics: include_diagnostics,
      extra: {
        remote_commit: false,
        mutation_allowed: false,
        ready: config[:ready],
        status: config[:ready] ? 'ready' : 'action_required',
        warnings: config[:warnings]
      }
    )
  end

  def provisioning_plan(inbox_id:, operation: 'update', include_diagnostics: false)
    config = config_builder.for_inbox(inbox_id)
    desired_state = desired_state_builder.for_inbox(inbox_id)
    plan = remote_plan_builder.build(operation: operation, desired_state: desired_state)

    product_payload(
      operation: 'provisioning_plan',
      config: config,
      include_diagnostics: include_diagnostics,
      extra: {
        remote_commit: false,
        mutation_allowed: false,
        provisioning_plan: product_plan(plan),
        warnings: config[:warnings]
      }
    )
  end

  def provision(inbox_id:, remote_commit: false, include_diagnostics: false)
    config = config_builder.for_inbox(inbox_id)
    desired_state = desired_state_builder.for_inbox(inbox_id)
    plan = remote_plan_builder.build(operation: 'update', desired_state: desired_state)
    provision_result = remote_provisioner.execute(
      operation: 'update',
      desired_state: desired_state,
      plan: plan,
      remote_commit: remote_commit
    )

    product_payload(
      operation: 'provision',
      config: config_builder.for_inbox(inbox_id),
      include_diagnostics: include_diagnostics,
      extra: provision_result.merge(provisioning_plan: product_plan(plan), warnings: config[:warnings])
    )
  end

  def reconcile(inbox_id:, include_diagnostics: false)
    config = config_builder.for_inbox(inbox_id)
    desired_state = desired_state_builder.for_inbox(inbox_id)
    reconciliation = reconciler.check(desired_state)

    product_payload(
      operation: 'reconcile',
      config: config_builder.for_inbox(inbox_id),
      include_diagnostics: include_diagnostics,
      extra: reconciliation.merge(remote_commit: false, mutation_allowed: false, warnings: config[:warnings])
    )
  end

  def provisioning_runs(inbox_id:)
    runs = account.telephony_provisioning_runs.where(inbox_id: inbox_id).recent.limit(20)

    {
      operation: 'provisioning_runs',
      remote_commit: false,
      mutation_allowed: false,
      provisioning_runs: runs.map(&:summary_payload)
    }
  end

  def create_channel(payload, dry_run: true, remote_commit: false, include_diagnostics: false)
    normalized = normalize_payload(payload)
    normalized = with_remote_shared_sipuni_credentials(normalized) if remote_commit_requested?(remote_commit)
    errors = validation_errors(normalized, require_profiles: normalized[:profiles_supplied])

    if dry_run || errors.any?
      return dry_run_payload(operation: 'create', normalized_payload: normalized, errors: errors, existing_config: nil,
                             steps: create_steps(normalized), include_diagnostics: include_diagnostics)
    end

    preflight_plan = remote_plan_builder.build(operation: 'create', desired_state: desired_state_for_payload(normalized, nil))
    if remote_commit_requested?(remote_commit) && remote_plan_blocked?(preflight_plan)
      return remote_plan_blocked_payload(
        operation: 'create',
        normalized_payload: normalized,
        plan: preflight_plan,
        steps: create_steps(normalized),
        include_diagnostics: include_diagnostics
      )
    end

    mutation_payload(
      'create',
      create_local_channel!(normalized),
      normalized,
      create_steps(normalized),
      remote_commit: remote_commit,
      include_diagnostics: include_diagnostics
    )
  end

  def update_channel(inbox_id:, payload:, dry_run: true, remote_commit: false, include_diagnostics: false)
    existing_config = config_builder.for_inbox(inbox_id)
    normalized = normalize_payload(payload, fallback: existing_config)
    errors = validation_errors(
      normalized,
      require_profiles: normalized[:profiles_supplied],
      profile_inbox_id: inbox_id,
      exclude_inbox_id: inbox_id
    )
    if existing_config.dig(
      :ownership, :read_only
    )
      errors << error('managed_ownership_required',
                      'Legacy/reference resources are read-only until managed migration is approved')
    end
    errors << error('active_calls_present', 'Channel has active calls and cannot be updated') if active_calls_present?(inbox_id)

    if dry_run || errors.any?
      return dry_run_payload(operation: 'update', normalized_payload: normalized, errors: errors, existing_config: existing_config,
                             steps: update_steps(normalized, existing_config), include_diagnostics: include_diagnostics)
    end

    mutation_payload(
      'update',
      update_local_channel!(inbox_id, normalized),
      normalized,
      update_steps(normalized, existing_config),
      remote_commit: remote_commit,
      include_diagnostics: include_diagnostics,
      existing_config: existing_config
    )
  end

  def delete_channel(inbox_id:, confirm: false, dry_run: true, remote_commit: false, include_diagnostics: false)
    existing_config = config_builder.for_inbox(inbox_id)
    errors = []
    errors << error('confirmation_required', 'Deletion requires explicit confirmation') unless confirm
    if existing_config.dig(
      :ownership, :read_only
    )
      errors << error('managed_ownership_required',
                      'Legacy/reference resources are read-only and cannot be deleted by provisioning')
    end
    errors << error('active_calls_present', 'Channel has active calls and cannot be deleted') if active_calls_present?(inbox_id)

    if dry_run || errors.any?
      return dry_run_payload(operation: 'delete', normalized_payload: { inbox_id: inbox_id, confirm: confirm }, errors: errors,
                             existing_config: existing_config, steps: delete_steps(existing_config), include_diagnostics: include_diagnostics)
    end

    remote_result = nil
    desired_state = desired_state_builder.for_inbox(inbox_id)
    plan = remote_plan_builder.build(operation: 'delete', desired_state: desired_state)
    if remote_commit_requested?(remote_commit)
      remote_result = remote_provisioner.execute(
        operation: 'delete',
        desired_state: desired_state,
        plan: plan,
        remote_commit: true
      )
      unless remote_result_succeeded?(remote_result)
        return delete_remote_failed_payload(inbox_id, confirm, existing_config, plan, remote_result,
                                            include_diagnostics: include_diagnostics)
      end
    end

    mutation_payload(
      'delete',
      delete_local_channel!(inbox_id),
      { inbox_id: inbox_id, confirm: confirm },
      delete_steps(existing_config),
      existing_config: existing_config,
      prebuilt_plan: plan,
      remote_result: remote_result,
      remote_commit: remote_commit,
      include_diagnostics: include_diagnostics
    )
  end

  private

  attr_reader :account, :current_user, :bridge_client, :config_builder

  def desired_state_builder
    @desired_state_builder ||= Telephony::VirtualPbx::DesiredStateBuilder.new(account: account)
  end

  def remote_plan_builder
    @remote_plan_builder ||= Telephony::VirtualPbx::RemotePlanBuilder.new(account: account)
  end

  def remote_provisioner
    @remote_provisioner ||= Telephony::VirtualPbx::RemoteProvisioner.new(account: account, current_user: current_user)
  end

  def reconciler
    @reconciler ||= Telephony::VirtualPbx::Reconciler.new(account: account)
  end

  def product_payload(operation:, config:, include_diagnostics:, extra: {})
    payload = {
      operation: operation,
      ui_config: config_builder.ui_config_from(config)
    }.merge(extra || {})
    payload[:diagnostics] = { config: config } if include_diagnostics
    payload
  end

  def product_plan(plan)
    plan.deep_dup.tap do |copy|
      operations = Array.wrap(copy[:operations] || copy['operations']).map do |operation|
        attrs = operation.with_indifferent_access
        attrs.slice(:key, :description, :risk, :owned, :shared, :conflict)
      end
      copy[:operations] = operations
      copy[:items] = product_plan_items
      copy.delete(:conflicts) if copy[:conflicts].blank?
    end
  end

  def product_plan_items
    [
      { code: 'validate_settings', status: 'ready' },
      { code: 'save_channel', status: 'ready' },
      { code: 'connect_number', status: 'requires_remote_commit' },
      { code: 'configure_routing', status: 'requires_remote_commit' },
      { code: 'remote_sync', status: 'requires_remote_commit' }
    ]
  end

  def desired_state_for_payload(normalized_payload, existing_config)
    config = (existing_config || {}).with_indifferent_access
    refs = generated_refs_for(normalized_payload, config)
    resources = (config[:resources] || {}).with_indifferent_access
    provider_connection = (resources[:provider_connection] || {}).with_indifferent_access
    ownership = (config[:ownership] || {}).with_indifferent_access

    Telephony::VirtualPbx::ConfigBuilder.sanitize(
      account_id: account.id,
      inbox_id: config[:inbox_id],
      channel_id: config[:channel_id],
      provider: 'fonoster',
      provider_kind: normalized_payload[:provider_kind] || config[:provider_kind],
      managed_by: MANAGED_BY_ONELINK,
      name: normalized_payload[:channel_name] || config[:name],
      phone_numbers: {
        display_phone_number: normalized_payload[:display_phone_number] || config.dig(:phone_numbers, :display_phone_number),
        provider_account_number: normalized_payload[:provider_account_number] || config.dig(:phone_numbers, :provider_account_number),
        ingress_number: normalized_payload[:ingress_number] || config.dig(:phone_numbers, :ingress_number),
        fonoster_tel_url: normalized_payload[:fonoster_tel_url] || config.dig(:phone_numbers, :fonoster_tel_url)
      }.compact,
      refs: {
        number_ref: refs[:number_ref],
        trunk_ref: refs[:trunk_ref],
        credentials_ref: refs[:credentials_ref],
        app_ref: first_present(resources[:app_ref], refs[:app_ref]),
        runtime_app_ref: first_present(resources[:runtime_app_ref], refs[:runtime_app_ref], resources[:app_ref], refs[:app_ref])
      }.compact,
      connection: (normalized_payload[:connection] || {}).merge(
        credentials_ref: first_present(
          normalized_payload.dig(:connection, :credentials_ref),
          normalized_payload.dig(:connection, :fonoster_credentials_ref),
          refs[:credentials_ref],
          provider_connection[:credentials_ref],
          provider_connection[:fonoster_credentials_ref]
        ),
        password_configured: normalized_payload.dig(:connection, :password).present? ||
          ActiveModel::Type::Boolean.new.cast(normalized_payload.dig(:connection, :password_configured)) ||
          provider_connection[:password_configured]
      ).compact,
      routing: normalized_payload[:routing] || config[:routing] || {},
      profiles: normalized_payload[:profiles] || config[:profiles] || [],
      ownership: {
        managed_by: ownership[:managed_by] || MANAGED_BY_ONELINK,
        ownership_status: ownership[:ownership_status] || LOCAL_OWNERSHIP_STATUS,
        read_only: ownership[:read_only] || false,
        onelink_account_id: account.id,
        onelink_inbox_id: config[:inbox_id],
        onelink_channel_id: config[:channel_id],
        onelink_number_binding_id: resources[:number_binding_id]
      }.compact,
      resources: {
        number_binding_id: resources[:number_binding_id],
        provider_connection_id: resources[:provider_connection_id]
      }.compact
    ).deep_symbolize_keys
  end

  def dry_run_payload(operation:, normalized_payload:, errors:, existing_config:, steps:, include_diagnostics: false)
    sanitized_payload = Telephony::VirtualPbx::ConfigBuilder.sanitize(normalized_payload)
    desired_state = desired_state_for_payload(normalized_payload, existing_config)
    plan = remote_plan_builder.build(operation: operation, desired_state: desired_state)

    payload = {
      operation: operation,
      dry_run: true,
      valid: errors.empty?,
      remote_commit: false,
      mutation_allowed: false,
      mutation_reason: 'phase1_read_only_dry_run',
      remote_mutation_allowed: false,
      remote_mutation_reason: REMOTE_MUTATION_REASON,
      status: dry_run_status(errors),
      account_id: account.id,
      requested_by_id: current_user&.id,
      ui_config: existing_config.present? ? config_builder.ui_config_from(existing_config) : nil,
      provisioning_plan: product_plan(plan),
      steps: steps,
      errors: errors,
      warnings: dry_run_warnings(existing_config)
    }.compact

    if include_diagnostics
      payload[:diagnostics] = {
        payload: sanitized_payload,
        provider_template: provider_template_for(normalized_payload, existing_config),
        generated_refs: generated_refs_for(normalized_payload, existing_config),
        bridge_operations: bridge_operations_for(operation, normalized_payload, existing_config: existing_config),
        existing_config: existing_config
      }.compact
    end

    payload
  end

  def remote_plan_blocked_payload(operation:, normalized_payload:, plan:, steps:, include_diagnostics: false)
    blocked_operations = Array.wrap(plan[:operations] || plan['operations']).map(&:with_indifferent_access).select do |operation_payload|
      operation_payload[:risk].to_s == 'blocked'
    end
    errors = blocked_operations.map do |operation_payload|
      error(
        operation_payload[:conflict].presence || operation_payload[:key].presence || 'remote_plan_blocked',
        operation_payload[:description].presence || 'Remote provisioning plan is blocked'
      )
    end

    payload = {
      operation: operation,
      dry_run: false,
      valid: false,
      status: 'blocked',
      local_commit: false,
      remote_commit: false,
      mutation_allowed: false,
      mutation_reason: 'remote_plan_blocked_before_local_commit',
      remote_mutation_allowed: false,
      remote_mutation_reason: 'REMOTE_PLAN_BLOCKED',
      account_id: account.id,
      requested_by_id: current_user&.id,
      provisioning_plan: product_plan(plan),
      steps: steps,
      errors: errors,
      warnings: []
    }.compact

    if include_diagnostics
      payload[:diagnostics] = {
        payload: Telephony::VirtualPbx::ConfigBuilder.sanitize(normalized_payload),
        provider_template: provider_template_for(normalized_payload, nil),
        generated_refs: generated_refs_for(normalized_payload, nil),
        bridge_operations: bridge_operations_for(operation, normalized_payload)
      }.compact
    end

    payload
  end

  def mutation_payload(operation, mutation_result, normalized_payload, steps, existing_config: nil, prebuilt_plan: nil, remote_result: nil,
                       remote_commit: false, include_diagnostics: false)
    config = mutation_result[:inbox_id].present? ? config_builder.for_inbox(mutation_result[:inbox_id]) : nil
    desired_state = if config.present?
                      desired_state_builder.for_inbox(config[:inbox_id])
                    else
                      desired_state_for_payload(normalized_payload, existing_config)
                    end
    desired_state = merge_transient_credentials(desired_state, normalized_payload)
    desired_state = merge_stale_sip_profile_cleanup(desired_state, mutation_result)
    desired_state = merge_replaced_sip_profile_cleanup(desired_state, existing_config)
    plan = prebuilt_plan || remote_plan_builder.build(operation: operation, desired_state: desired_state)
    if remote_result.blank? && config.present? && remote_commit_requested?(remote_commit)
      remote_result = remote_provisioner.execute(
        operation: operation,
        desired_state: desired_state,
        plan: plan,
        remote_commit: true
      )
      config = config_builder.for_inbox(config[:inbox_id])
    end

    remote_errors = Array.wrap(remote_result&.dig(:errors))
    remote_committed = remote_result.present? ? ActiveModel::Type::Boolean.new.cast(remote_result[:remote_commit]) : false

    payload = {
      operation: operation,
      dry_run: false,
      valid: true,
      status: remote_result&.dig(:status) || 'local_committed',
      local_commit: true,
      remote_commit: remote_committed,
      mutation_allowed: true,
      remote_mutation_allowed: remote_commit_requested?(remote_commit),
      remote_mutation_reason: remote_result.present? ? nil : REMOTE_MUTATION_REASON,
      mutation_reason: remote_result.present? ? 'local_commit_remote_sync_attempted' : 'local_commit_remote_mutation_disabled',
      account_id: account.id,
      requested_by_id: current_user&.id,
      ui_config: config.present? ? config_builder.ui_config_from(config) : nil,
      provisioning_plan: product_plan(plan),
      provisioning_run: remote_result&.dig(:provisioning_run),
      executed_operations: remote_result&.dig(:executed_operations),
      reconciliation: remote_result&.dig(:reconciliation),
      config: include_diagnostics ? config : nil,
      deleted: mutation_result[:deleted],
      deleted_inbox_id: mutation_result[:deleted_inbox_id],
      steps: steps,
      errors: remote_errors,
      warnings: mutation_warnings(remote_result)
    }.compact

    if include_diagnostics
      payload[:diagnostics] = {
        payload: Telephony::VirtualPbx::ConfigBuilder.sanitize(normalized_payload),
        provider_template: provider_template_for(normalized_payload, existing_config),
        generated_refs: generated_refs_for(normalized_payload, existing_config),
        bridge_operations: bridge_operations_for(operation, normalized_payload, existing_config: existing_config),
        config: config
      }.compact
    end

    payload
  end

  def delete_remote_failed_payload(inbox_id, confirm, existing_config, plan, remote_result, include_diagnostics: false)
    payload = {
      operation: 'delete',
      dry_run: false,
      valid: false,
      status: remote_result[:status],
      local_commit: false,
      remote_commit: ActiveModel::Type::Boolean.new.cast(remote_result[:remote_commit]),
      mutation_allowed: true,
      remote_mutation_allowed: true,
      mutation_reason: 'remote_delete_failed_local_delete_skipped',
      account_id: account.id,
      requested_by_id: current_user&.id,
      ui_config: config_builder.ui_config_from(existing_config),
      provisioning_plan: product_plan(plan),
      provisioning_run: remote_result[:provisioning_run],
      executed_operations: remote_result[:executed_operations],
      reconciliation: remote_result[:reconciliation],
      deleted: false,
      deleted_inbox_id: nil,
      steps: delete_steps(existing_config),
      errors: Array.wrap(remote_result[:errors]),
      warnings: [warning('local_delete_skipped', 'Local channel was not deleted because remote Fonoster cleanup failed')]
    }.compact

    if include_diagnostics
      payload[:diagnostics] = {
        payload: { inbox_id: inbox_id, confirm: confirm },
        generated_refs: existing_config_refs(existing_config),
        bridge_operations: delete_bridge_operations(existing_config),
        existing_config: existing_config
      }.compact
    end

    payload
  end

  def merge_transient_credentials(desired_state, normalized_payload)
    state = desired_state.deep_dup.deep_symbolize_keys
    merge_transient_connection_credentials!(state, normalized_payload)
    merge_transient_profile_credentials!(state, normalized_payload)
    state
  end

  def merge_stale_sip_profile_cleanup(desired_state, mutation_result)
    stale_profiles = Array.wrap(mutation_result[:stale_sip_profiles] || mutation_result['stale_sip_profiles']).compact
    return desired_state if stale_profiles.blank?

    desired_state.deep_dup.tap do |state|
      state[:stale_profiles] = merge_stale_profile_snapshots(state[:stale_profiles], stale_profiles)
    end
  end

  def merge_replaced_sip_profile_cleanup(desired_state, existing_config)
    existing_profiles = Array.wrap(existing_config&.dig(:profiles))
    return desired_state if existing_profiles.blank?

    current_profiles = Array.wrap(desired_state[:profiles]).map(&:with_indifferent_access)
    stale_profiles = existing_profiles.filter_map do |profile|
      attrs = profile.with_indifferent_access
      current = current_profiles.find { |candidate| candidate[:id].present? && candidate[:id].to_s == attrs[:id].to_s }
      current ||= current_profiles.find { |candidate| candidate[:user_id].to_s == attrs[:user_id].to_s }
      next if current.present? && !sip_profile_remote_identity_changed?(attrs, current)

      sip_profile_cleanup_snapshot_from_hash(attrs)
    end
    return desired_state if stale_profiles.blank?

    desired_state.deep_dup.tap do |state|
      state[:stale_profiles] = merge_stale_profile_snapshots(state[:stale_profiles], stale_profiles)
    end
  end

  def sip_profile_remote_identity_changed?(previous_profile, current_profile)
    previous_profile[:internal_extension].to_s != current_profile[:internal_extension].to_s ||
      previous_profile[:sip_username].to_s != current_profile[:sip_username].to_s ||
      (previous_profile[:fonoster_agent_ref].presence || previous_profile[:agent_ref]).to_s !=
        (current_profile[:fonoster_agent_ref].presence || current_profile[:agent_ref]).to_s ||
      (previous_profile[:fonoster_credentials_ref].presence || previous_profile[:credentials_ref]).to_s !=
        (current_profile[:fonoster_credentials_ref].presence || current_profile[:credentials_ref]).to_s
  end

  def sip_profile_cleanup_snapshot_from_hash(attrs)
    {
      id: attrs[:id],
      user_id: attrs[:user_id],
      internal_extension: attrs[:internal_extension],
      sip_username: attrs[:sip_username],
      agent_ref: attrs[:fonoster_agent_ref].presence || attrs[:agent_ref],
      local_agent_ref: attrs[:agent_ref],
      credentials_ref: attrs[:fonoster_credentials_ref].presence || attrs[:credentials_ref],
      local_credentials_ref: attrs[:credentials_ref],
      fonoster_agent_ref: attrs[:fonoster_agent_ref],
      fonoster_credentials_ref: attrs[:fonoster_credentials_ref],
      availability_mode: attrs[:availability_mode],
      status: attrs[:status],
      enabled: attrs[:enabled]
    }.compact
  end

  def merge_stale_profile_snapshots(*groups)
    groups.flatten.compact.uniq { |profile| [profile[:agent_ref], profile[:credentials_ref], profile[:sip_username], profile[:internal_extension]] }
  end

  def merge_transient_connection_credentials!(state, normalized_payload)
    password = normalized_payload.dig(:connection, :password).presence
    return if password.blank?

    state[:connection] ||= {}
    state[:connection][:password] = password
  end

  def merge_transient_profile_credentials!(state, normalized_payload)
    transient_profiles = Array.wrap(normalized_payload[:profiles]).select { |profile| profile[:sip_password].present? }
    return if transient_profiles.blank?

    desired_profiles = Array.wrap(state[:profiles])
    transient_profiles.each do |profile|
      desired_profile = desired_profiles.find do |candidate|
        candidate[:user_id].to_s == profile[:user_id].to_s &&
          candidate[:internal_extension].to_s == profile[:internal_extension].to_s
      end
      next if desired_profile.blank?

      desired_profile[:sip_username] = profile[:sip_username] if profile.key?(:sip_username)
      desired_profile[:sip_password] = profile[:sip_password]
    end
  end

  def with_remote_shared_sipuni_credentials(payload)
    attrs = payload.deep_dup
    connection = (attrs[:connection] || {}).with_indifferent_access
    return attrs unless attrs[:provider_kind].to_s == 'sipuni'
    return attrs if connection[:username].present? || connection[:password].present? || connection[:credentials_ref].present? ||
                    connection[:fonoster_credentials_ref].present?

    credential = remote_shared_sipuni_trunk_credential
    return attrs if credential.blank?

    attrs[:connection] = connection.merge(
      username: credential[:username],
      credentials_ref: credential[:ref],
      fonoster_credentials_ref: credential[:ref],
      password_configured: true
    ).compact
    attrs
  end

  def remote_shared_sipuni_trunk_credential
    trunk_ref = sipuni_trunk_ref
    trunk = remote_bridge_get("/telephony/trunks/#{CGI.escape(trunk_ref)}")
    list_item = remote_shared_sipuni_trunk_from_list(trunk_ref)
    outbound_credentials = (list_item&.dig(:outboundCredentials) || list_item&.dig('outboundCredentials') || {}).with_indifferent_access
    credential_ref = first_present(
      trunk&.with_indifferent_access&.dig(:outboundCredentialsRef),
      outbound_credentials[:ref]
    )
    username = outbound_credentials[:username].presence
    username ||= remote_shared_credential_username(credential_ref)
    return if credential_ref.blank? || username.blank?

    { ref: credential_ref, username: username }
  end

  def remote_shared_sipuni_trunk_from_list(trunk_ref)
    response = remote_bridge_get('/telephony/trunks')
    Array.wrap(response&.with_indifferent_access&.dig(:items)).find do |attrs|
      attrs.with_indifferent_access[:ref].to_s == trunk_ref.to_s
    end
  end

  def remote_shared_credential_username(credential_ref)
    return if credential_ref.blank?

    remote_bridge_get("/telephony/credentials/#{CGI.escape(credential_ref)}")&.with_indifferent_access&.dig(:username)
  end

  def remote_bridge_get(path)
    effective_bridge_client.get(path)
  rescue Telephony::Error => e
    Rails.logger.warn("[VIRTUAL_PBX] remote shared Sipuni credential adoption skipped code=#{e.code} status=#{e.status}")
    nil
  end

  def effective_bridge_client
    bridge_client || Telephony::BridgeClient.new(account_id: account.id)
  end

  def normalize_payload(payload, fallback: nil)
    source = payload.to_h.deep_stringify_keys
    fallback_phone_numbers = fallback&.fetch(:phone_numbers, {}) || {}
    fallback_routing = fallback&.fetch(:routing, {}) || {}

    provider_kind = normalize_provider_kind(source['provider_kind'].presence || fallback&.dig(:provider_kind))
    ingress_number = normalize_technical_number(
      first_present(
        source['ingress_number'],
        source['sipuni_ingress_number'],
        source['provider_number'],
        fallback_phone_numbers[:ingress_number]
      )
    )
    provider_account_number = normalize_technical_number(
      first_present(
        source['provider_account_number'],
        source['sipuni_account_number'],
        source['account_number'],
        fallback_phone_numbers[:provider_account_number],
        ingress_number
      )
    )
    profiles_supplied = source.key?('profiles')

    normalized = {
      provider_kind: provider_kind,
      channel_name: first_present(source['channel_name'], source['name'], fallback&.dig(:name)),
      display_phone_number: first_present(source['display_phone_number'], source['phone_number'], fallback_phone_numbers[:display_phone_number]),
      provider_account_number: provider_account_number,
      ingress_number: ingress_number,
      fonoster_tel_url: normalize_tel_url(
        first_present(source['fonoster_tel_url'], source['tel_url'], fallback_phone_numbers[:fonoster_tel_url], tel_url_for(ingress_number))
      ),
      connection: normalize_connection(
        source['connection'] || {},
        provider_kind,
        fallback&.dig(:resources, :provider_connection)
      ),
      profiles: profiles_supplied ? normalize_profiles(source['profiles']) : normalize_existing_profiles(fallback&.dig(:profiles)),
      profiles_supplied: profiles_supplied,
      routing: normalize_routing(source['routing'] || {}, fallback_routing, profiles_supplied: profiles_supplied),
      metadata: normalize_metadata(source['metadata'] || {})
    }.compact

    normalized[:profiles] = normalized[:profiles].map do |profile|
      profile_with_default_availability_mode(profile, normalized)
    end
    normalized
  end

  def normalize_connection(source, provider_kind, fallback)
    source = source.to_h.deep_stringify_keys
    fallback = (fallback || {}).with_indifferent_access
    template = Telephony::VirtualPbx::ConfigBuilder::PROVIDER_TEMPLATES.fetch(provider_kind, {})
    port_source = source.key?('port') ? source['port'] : first_present(fallback[:port], template[:default_port], 5060)
    username = first_present(
      source['username'],
      fallback[:username]
    )
    password = source['password'].presence
    send_register = if source.key?('send_register')
                      ActiveModel::Type::Boolean.new.cast(source['send_register'])
                    elsif fallback.key?(:send_register)
                      ActiveModel::Type::Boolean.new.cast(fallback[:send_register])
                    else
                      default_send_register_for(provider_kind, username: username, password: password)
                    end

    {
      host: first_present(source['host'], fallback[:host]),
      port: normalize_port(port_source),
      transport: first_present(source['transport'], fallback[:transport], template[:default_transport], 'udp'),
      username: username,
      password: password,
      send_register: send_register
    }.compact
  end

  def default_send_register_for(provider_kind, username:, password:)
    return username.present? || password.present? if provider_kind.to_s == 'asterisk_analog'
    return false unless provider_kind.to_s == 'sipuni'

    username.present? || password.present?
  end

  def normalize_port(value)
    normalized = value.to_s.strip
    return if normalized.blank? || !normalized.match?(/\A\d+\z/)

    port = normalized.to_i
    port if (1..65_535).cover?(port)
  end

  def normalize_profiles(source)
    Array.wrap(source).map do |profile|
      attrs = profile.to_h.deep_stringify_keys
      normalized = {
        user_id: attrs['user_id'].presence&.to_i,
        internal_extension: attrs['internal_extension'].presence,
        sip_password_configured: ActiveModel::Type::Boolean.new.cast(attrs['sip_password_configured']),
        enabled: attrs.key?('enabled') ? ActiveModel::Type::Boolean.new.cast(attrs['enabled']) : true
      }.compact
      normalized[:sip_username] = attrs['sip_username'].presence if attrs.key?('sip_username')
      normalized[:sip_password] = attrs['sip_password'].presence if attrs.key?('sip_password')
      normalized[:availability_mode] = attrs['availability_mode'].presence if attrs.key?('availability_mode')
      normalized
    end
  end

  def normalize_existing_profiles(profiles)
    Array.wrap(profiles).map do |profile|
      attrs = profile.with_indifferent_access
      {
        user_id: attrs[:user_id],
        internal_extension: attrs[:internal_extension],
        sip_username: attrs[:sip_username],
        sip_password_configured: ActiveModel::Type::Boolean.new.cast(attrs[:sip_password_configured]),
        availability_mode: attrs[:availability_mode],
        enabled: attrs.key?(:enabled) ? attrs[:enabled] : true
      }.compact
    end
  end

  def profile_with_default_availability_mode(profile, payload)
    return profile if profile[:availability_mode].present?

    profile.merge(availability_mode: default_profile_availability_mode(payload[:provider_kind]))
  end

  def default_profile_availability_mode(provider_kind)
    return 'browser_webphone' if provider_kind.to_s == 'sipuni'

    'external_extension'
  end

  def normalize_routing(source, fallback, profiles_supplied: false)
    source = source.to_h.deep_stringify_keys

    {
      mode: source['mode'].presence || fallback[:mode] || DEFAULT_ROUTE_MODE,
      fallback_mode: source['fallback_mode'].presence || fallback[:fallback_mode] || DEFAULT_FALLBACK_MODE,
      ai_enabled: normalized_routing_ai_enabled(source, fallback),
      operator_distribution_mode: normalized_operator_distribution_mode(source, fallback),
      operator_agent_aor: normalized_operator_agent_aor(source, fallback, profiles_supplied: profiles_supplied)
    }.compact
  end

  def normalized_routing_ai_enabled(source, fallback)
    value = source.key?('ai_enabled') ? source['ai_enabled'] : fallback[:ai_enabled]

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def normalized_operator_distribution_mode(source, fallback)
    value = source.key?('operator_distribution_mode') ? source['operator_distribution_mode'] : fallback[:operator_distribution_mode]
    value = DEFAULT_OPERATOR_DISTRIBUTION_MODE if value.blank?

    Telephony::RoutingPolicy.normalized_operator_distribution_mode(value)
  end

  def normalized_operator_agent_aor(source, fallback, profiles_supplied: false)
    return source['operator_agent_aor'].presence if source.key?('operator_agent_aor')
    return nil if profiles_supplied

    fallback[:operator_agent_aor]
  end

  def normalize_metadata(source)
    source.to_h.deep_stringify_keys.slice('environment', 'source', 'notes')
  end

  def validation_errors(payload, require_profiles: true, profile_inbox_id: nil, check_duplicate_number_ref: true, exclude_inbox_id: nil)
    [].tap do |errors|
      unless payload[:provider_kind].in?(ALLOWED_PROVIDER_KINDS)
        errors << error('provider_kind_invalid',
                        'provider_kind must be asterisk_analog or sipuni')
      end
      errors << error('channel_name_required', 'channel_name is required') if payload[:channel_name].blank?
      errors << error('display_phone_number_required', 'display_phone_number is required') if payload[:display_phone_number].blank?
      if payload[:display_phone_number].present? && !payload[:display_phone_number].match?(/\A\+[1-9]\d{1,14}\z/)
        errors << error('display_phone_number_invalid', 'display_phone_number must be an E.164 external number')
      end
      errors << error('ingress_number_required', 'ingress_number is required') if payload[:ingress_number].blank?
      errors << error('connection_host_required', 'connection.host is required') if payload.dig(:connection, :host).blank?
      errors << connection_port_invalid_error if payload.dig(:connection, :port).blank?
      if check_duplicate_number_ref && number_ref_taken?(payload, exclude_inbox_id: exclude_inbox_id)
        errors << error('number_ref_taken', 'Generated number_ref is already used by another channel')
      end
      if shared_sipuni_trunk_uses_employee_profile?(payload, inbox_id: profile_inbox_id)
        errors << error(
          'shared_sipuni_trunk_uses_employee_profile',
          'connection.username must be a shared Sipuni trunk login, not an employee SIP profile username'
        )
      end
      errors.concat(profile_errors(payload[:profiles], inbox_id: profile_inbox_id)) if require_profiles
    end
  end

  def connection_port_invalid_error
    error('connection_port_invalid', 'connection.port must be an integer between 1 and 65535')
  end

  def profile_errors(profiles, inbox_id: nil)
    Array.wrap(profiles).each_with_index.with_object([]) do |(profile, index), errors|
      errors << error('profile_user_required', "profiles[#{index}].user_id is required") if profile[:user_id].blank?
      if profile[:internal_extension].blank?
        errors << error('profile_internal_extension_required',
                        "profiles[#{index}].internal_extension is required")
      end
      if sip_credentials_pair_invalid?(profile, inbox_id: inbox_id)
        errors << error('profile_sip_credentials_pair_required', "profiles[#{index}] SIP username/password must be provided together")
      end
      if profile[:availability_mode].present? && !Telephony::SipProfile::AVAILABILITY_MODES.include?(profile[:availability_mode].to_s)
        errors << error('profile_availability_mode_invalid', "profiles[#{index}].availability_mode is invalid")
      end
      next if profile[:user_id].blank?

      unless account.account_users.exists?(user_id: profile[:user_id])
        errors << error('profile_user_not_in_account', "profiles[#{index}].user_id must belong to the account")
        next
      end

      next if inbox_id.blank? || InboxMember.exists?(inbox_id: inbox_id, user_id: profile[:user_id])

      errors << error('profile_user_not_in_inbox', "profiles[#{index}].user_id must be an inbox collaborator before SIP assignment")
    end
  end

  def sip_credentials_pair_invalid?(profile, inbox_id: nil)
    has_username = profile[:sip_username].present?
    has_password = profile[:sip_password].present?
    return has_password unless has_username
    return false if has_password

    !existing_sip_profile_password_configured?(profile, inbox_id: inbox_id)
  end

  def existing_sip_profile_password_configured?(profile, inbox_id: nil)
    return false if inbox_id.blank? || profile[:user_id].blank? || profile[:internal_extension].blank?

    existing_profile = account.telephony_sip_profiles.find_by(
      inbox_id: inbox_id,
      user_id: profile[:user_id],
      internal_extension: profile[:internal_extension]
    )
    existing_profile ||= reusable_sip_profile_credentials_for(profile, inbox_id: inbox_id)
    return false if existing_profile.blank? || existing_profile.password_secret_ref.blank?

    existing_profile.sip_username.to_s == profile[:sip_username].to_s
  end

  def shared_sipuni_trunk_uses_employee_profile?(payload, inbox_id: nil)
    return false unless payload[:provider_kind].to_s == 'sipuni'
    return false if payload.dig(:routing, :operator_distribution_mode).to_s == Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_TARGETED

    trunk_username = normalized_sip_identity(payload.dig(:connection, :username))
    return false if trunk_username.blank?

    sip_profile_usernames_for_validation(payload, inbox_id: inbox_id).include?(trunk_username)
  end

  def sip_profile_usernames_for_validation(payload, inbox_id: nil)
    if payload.key?(:profiles)
      return Array.wrap(payload[:profiles]).filter_map do |profile|
        profile_sip_username_for_validation(profile, inbox_id: inbox_id)
      end
    end

    return [] if inbox_id.blank?

    account.telephony_sip_profiles.where(inbox_id: inbox_id).filter_map { |profile| normalized_sip_identity(profile.sip_username) }
  end

  def profile_sip_username_for_validation(profile, inbox_id: nil)
    attrs = profile.with_indifferent_access
    return normalized_sip_identity(attrs[:sip_username]) if attrs.key?(:sip_username)

    normalized_sip_identity(existing_sip_username_for_profile(attrs, inbox_id: inbox_id))
  end

  def existing_sip_username_for_profile(profile, inbox_id: nil)
    return if inbox_id.blank? || profile[:user_id].blank? || profile[:internal_extension].blank?

    account.telephony_sip_profiles.find_by(
      inbox_id: inbox_id,
      user_id: profile[:user_id],
      internal_extension: profile[:internal_extension]
    )&.sip_username
  end

  def normalized_sip_identity(value)
    value.to_s.strip.presence
  end

  def reusable_sip_profile_credentials_for(profile, inbox_id:)
    return if inbox_id.blank? || profile[:internal_extension].blank? || profile[:sip_username].blank?

    matching_profiles = account.telephony_sip_profiles
                               .where(inbox_id: inbox_id, internal_extension: profile[:internal_extension], sip_username: profile[:sip_username])
                               .where.not(password_secret_ref: [nil, ''])
                               .to_a
    return unless matching_profiles.one?

    matching_profiles.first
  end

  def password_secret_ref_for(profile_record, profile, payload, index, sip_username:)
    return nil if sip_username.blank?
    return generated_refs(payload)[:profile_secret_refs][index] if profile[:sip_password].present?

    profile_record.password_secret_ref
  end

  def credentials_ref_for(profile_record, profile, payload, index, sip_username:)
    return nil if sip_username.blank?
    return generated_refs(payload)[:profile_secret_refs][index] if profile[:sip_password].present?

    profile_record.credentials_ref
  end

  def create_local_channel!(payload)
    result = nil
    ActiveRecord::Base.transaction do
      refs = generated_refs(payload)
      provider_connection = upsert_provider_connection!(payload, refs: refs)
      channel = Channel::Voice.create!(account: account, phone_number: payload[:display_phone_number], provider: 'fonoster',
                                       provider_config: provider_config_for(payload, provider_connection, refs: refs))
      inbox = Inbox.create!(account: account, channel: channel, name: payload[:channel_name])
      ensure_inbox_members_for_profiles!(inbox, payload)
      binding = upsert_number_binding!(inbox, channel, payload, provider_connection, refs: refs)
      upsert_routing_policy!(binding, payload)
      stale_sip_profiles = upsert_sip_profiles!(inbox, provider_connection, payload) if payload[:profiles_supplied]
      reconcile_legacy_agent_bindings!(inbox) if payload[:profiles_supplied]
      result = { inbox_id: inbox.id, stale_sip_profiles: stale_sip_profiles }
    end
    result
  end

  def update_local_channel!(inbox_id, payload)
    result = nil
    ActiveRecord::Base.transaction do
      inbox = account.inboxes.find(inbox_id)
      channel = inbox.channel
      binding = inbox.telephony_number_binding
      existing_config = config_builder.for_inbox(inbox_id)
      refs = generated_refs_for(payload, existing_config)
      provider_connection = upsert_provider_connection!(payload, existing: binding&.provider_connection, refs: refs)

      inbox.update!(name: payload[:channel_name])
      channel.update!(phone_number: payload[:display_phone_number],
                      provider_config: provider_config_for(payload, provider_connection, channel.provider_config_hash, refs: refs))
      binding = upsert_number_binding!(inbox, channel, payload, provider_connection, refs: refs)
      upsert_routing_policy!(binding, payload)
      if payload[:profiles_supplied]
        upsert_sip_profiles!(inbox, provider_connection, payload)
        reconcile_legacy_agent_bindings!(inbox)
      end
      result = { inbox_id: inbox.id }
    end
    result
  end

  def delete_local_channel!(inbox_id)
    result = nil
    ActiveRecord::Base.transaction do
      inbox = account.inboxes.find(inbox_id)
      binding = inbox.telephony_number_binding
      provider_connection = binding&.provider_connection
      deleted_inbox_id = inbox.id

      nullify_provisioning_run_links!(inbox: inbox, binding: binding)
      delete_assignment_decision_logs_for_inbox!(inbox)
      delete_communication_thread_links_for_inbox!(inbox)
      inbox.telephony_sip_profiles.destroy_all
      inbox.destroy!
      destroy_provider_connection_if_orphaned!(provider_connection)
      result = { deleted: true, deleted_inbox_id: deleted_inbox_id }
    end
    result
  end

  def upsert_provider_connection!(payload, existing: nil, refs: generated_refs(payload))
    connection_name = provider_connection_name(payload, refs: refs)
    connection = existing || account.telephony_provider_connections.find_or_initialize_by(
      provider_kind: payload[:provider_kind],
      name: connection_name
    )
    connection_credentials_ref = provider_connection_credentials_ref(payload, refs)
    connection.assign_attributes(
      provider_kind: payload[:provider_kind],
      name: connection_name,
      host: payload.dig(:connection, :host),
      port: payload.dig(:connection, :port),
      transport: payload.dig(:connection, :transport),
      username: payload.dig(:connection, :username),
      password_secret_ref: if provider_connection_password_configured?(payload)
                             connection_credentials_ref
                           else
                             connection.password_secret_ref
                           end,
      credentials_ref: connection_credentials_ref,
      fonoster_credentials_ref: payload.dig(:connection, :fonoster_credentials_ref).presence || connection.fonoster_credentials_ref,
      fonoster_trunk_ref: refs[:trunk_ref],
      send_register: ActiveModel::Type::Boolean.new.cast(payload.dig(:connection, :send_register)),
      status: 'active',
      managed_by: MANAGED_BY_ONELINK,
      ownership_status: LOCAL_OWNERSHIP_STATUS,
      metadata: payload[:metadata],
      updated_by: current_user
    )
    connection.created_by ||= current_user if connection.new_record?
    connection.save!
    connection
  end

  def provider_connection_credentials_ref(payload, refs)
    first_present(
      payload.dig(:connection, :credentials_ref),
      payload.dig(:connection, :fonoster_credentials_ref),
      refs[:credentials_ref]
    )
  end

  def provider_connection_password_configured?(payload)
    payload.dig(:connection, :password).present? ||
      ActiveModel::Type::Boolean.new.cast(payload.dig(:connection, :password_configured))
  end

  def upsert_number_binding!(inbox, channel, payload, provider_connection, refs: generated_refs(payload))
    binding = inbox.telephony_number_binding || inbox.build_telephony_number_binding(account: account)
    binding.assign_attributes(
      account: account,
      provider: 'fonoster',
      number_ref: refs[:number_ref],
      phone_number: payload[:ingress_number],
      display_phone_number: payload[:display_phone_number],
      provider_account_number: payload[:provider_account_number],
      ingress_number: payload[:ingress_number],
      fonoster_tel_url: payload[:fonoster_tel_url],
      app_ref: channel.provider_config_hash.with_indifferent_access[:app_ref],
      trunk_ref: refs[:trunk_ref],
      provider_connection: provider_connection,
      managed_by: MANAGED_BY_ONELINK,
      ownership_status: LOCAL_OWNERSHIP_STATUS,
      metadata: payload[:metadata].merge(provider_kind: payload[:provider_kind], source: payload.dig(:metadata, 'source')).compact,
      last_synced_at: Time.current
    )
    binding.save!
    binding
  end

  def upsert_routing_policy!(binding, payload)
    policy = binding.routing_policy || binding.build_routing_policy(account: account)
    policy.assign_attributes(
      account: account,
      mode: payload.dig(:routing, :mode),
      fallback_mode: payload.dig(:routing, :fallback_mode),
      ai_enabled: ActiveModel::Type::Boolean.new.cast(payload.dig(:routing, :ai_enabled)),
      operator_agent_aor: operator_agent_aor_for(payload),
      settings: (policy.settings || {}).merge(
        'virtual_pbx_local' => true,
        'operator_distribution_mode' => payload.dig(:routing, :operator_distribution_mode)
      )
    )
    policy.save!
    policy
  end

  def upsert_sip_profiles!(inbox, provider_connection, payload)
    desired_keys = []
    stale_profiles = []
    Array.wrap(payload[:profiles]).each_with_index do |profile, index|
      profile_record = sip_profile_record_for(inbox, profile)
      previous_profile = sip_profile_cleanup_snapshot(profile_record) if profile_record.persisted?
      sip_username = profile.key?(:sip_username) ? profile[:sip_username] : profile_record.sip_username
      availability_mode = profile_availability_mode(profile, payload)
      agent_ref = generated_refs(payload)[:profile_refs][index]
      credentials_ref = credentials_ref_for(profile_record, profile, payload, index, sip_username: sip_username)
      profile_record.assign_attributes(
        inbox: inbox,
        user_id: profile[:user_id],
        internal_extension: profile[:internal_extension],
        provider_connection: provider_connection,
        sip_username: sip_username,
        password_secret_ref: password_secret_ref_for(profile_record, profile, payload, index, sip_username: sip_username),
        sip_host: profile_sip_host(profile, payload),
        agent_ref: agent_ref,
        agent_aor: generated_profile_aor(profile, payload),
        fonoster_agent_ref: profile_record.fonoster_agent_ref.presence || agent_ref,
        credentials_ref: credentials_ref,
        enabled: profile.fetch(:enabled, true),
        availability_mode: availability_mode,
        status: 'active',
        managed_by: MANAGED_BY_ONELINK,
        ownership_status: LOCAL_OWNERSHIP_STATUS,
        metadata: { provider_kind: payload[:provider_kind] }
      )
      stale_profiles << previous_profile if stale_sip_profile_cleanup_required?(previous_profile, profile_record)
      profile_record.save!
      desired_keys << profile_record.id
    end
    removed_profiles = inbox.telephony_sip_profiles.where.not(id: desired_keys).to_a
    stale_profiles.concat(removed_profiles.filter_map { |profile| sip_profile_cleanup_snapshot(profile) })
    removed_profiles.each(&:destroy!)
    stale_profiles.compact.uniq { |profile| [profile[:agent_ref], profile[:credentials_ref], profile[:sip_username], profile[:internal_extension]] }
  end

  def reconcile_legacy_agent_bindings!(inbox)
    Telephony::LegacyAgentBindingReconciliationService.new(account: account, inbox: inbox).perform
  end

  def sip_profile_cleanup_snapshot(profile_record)
    return if profile_record.blank?

    {
      id: profile_record.id,
      user_id: profile_record.user_id,
      internal_extension: profile_record.internal_extension,
      sip_username: profile_record.sip_username,
      agent_ref: profile_record.fonoster_agent_ref.presence || profile_record.agent_ref,
      local_agent_ref: profile_record.agent_ref,
      credentials_ref: profile_record.fonoster_credentials_ref.presence || profile_record.credentials_ref,
      local_credentials_ref: profile_record.credentials_ref,
      fonoster_agent_ref: profile_record.fonoster_agent_ref,
      fonoster_credentials_ref: profile_record.fonoster_credentials_ref,
      availability_mode: profile_record.availability_mode,
      status: profile_record.status,
      enabled: profile_record.enabled
    }.compact
  end

  def stale_sip_profile_cleanup_required?(previous_profile, profile_record)
    return false if previous_profile.blank?

    previous_profile[:agent_ref].to_s != (profile_record.fonoster_agent_ref.presence || profile_record.agent_ref).to_s ||
      previous_profile[:credentials_ref].to_s != (profile_record.fonoster_credentials_ref.presence || profile_record.credentials_ref).to_s ||
      previous_profile[:sip_username].to_s != profile_record.sip_username.to_s ||
      previous_profile[:internal_extension].to_s != profile_record.internal_extension.to_s
  end

  def sip_profile_record_for(inbox, profile)
    exact_profile = account.telephony_sip_profiles.find_by(
      inbox: inbox,
      user_id: profile[:user_id],
      internal_extension: profile[:internal_extension]
    )
    return exact_profile if exact_profile.present?

    extension_profile = reassignable_sip_profile_for(inbox, profile)
    return extension_profile if extension_profile.present?

    if sip_credentials_omitted?(profile)
      existing_profiles = account.telephony_sip_profiles.where(inbox: inbox, user_id: profile[:user_id])
      return existing_profiles.first if existing_profiles.one?
    end

    account.telephony_sip_profiles.new(inbox: inbox, user_id: profile[:user_id], internal_extension: profile[:internal_extension])
  end

  def reassignable_sip_profile_for(inbox, profile)
    return if inbox.blank? || profile[:internal_extension].blank?

    existing_profiles = account.telephony_sip_profiles.where(inbox: inbox, internal_extension: profile[:internal_extension]).to_a
    return unless existing_profiles.one?

    existing_profiles.first
  end

  def sip_credentials_omitted?(profile)
    !profile.key?(:sip_username) && !profile.key?(:sip_password)
  end

  def provider_config_for(payload, provider_connection, base = {}, refs: generated_refs(payload))
    runtime_app_ref = runtime_app_ref_for(base, refs)

    base.with_indifferent_access.merge(
      provider_kind: payload[:provider_kind],
      number_ref: refs[:number_ref],
      app_ref: runtime_app_ref,
      runtime_app_ref: runtime_app_ref,
      trunk_ref: refs[:trunk_ref],
      display_phone_number: payload[:display_phone_number],
      provider_account_number: payload[:provider_account_number],
      ingress_number: payload[:ingress_number],
      fonoster_tel_url: payload[:fonoster_tel_url],
      routing_mode: payload.dig(:routing, :mode),
      fallback_mode: payload.dig(:routing, :fallback_mode),
      operator_distribution_mode: payload.dig(:routing, :operator_distribution_mode),
      operator_agent_aor: operator_agent_aor_for(payload),
      provider_connection_id: provider_connection.id,
      managed_by: MANAGED_BY_ONELINK,
      ownership_status: LOCAL_OWNERSHIP_STATUS,
      source: payload.dig(:metadata, 'source') || payload[:provider_kind]
    ).compact
  end

  def provider_connection_name(payload, refs: generated_refs(payload))
    first_present(refs[:trunk_ref], refs[:number_ref], payload[:channel_name], payload[:provider_kind])
  end

  def operator_agent_aor_for(payload)
    explicit_target = payload.dig(:routing, :operator_agent_aor).presence
    return explicit_target if explicit_target.present?
    return unless payload.dig(:routing, :operator_distribution_mode) == Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_TARGETED

    generated_profile_aor(Array.wrap(payload[:profiles]).first || {}, payload)
  end

  def generated_profile_aor(profile, payload)
    extension = profile[:internal_extension].presence || 'operator'
    host = browser_webphone_profile?(profile, payload) ? operator_sip_domain : payload.dig(:connection, :host).presence || 'voice.local'
    "sip:#{extension}@#{host}"
  end

  def profile_sip_host(profile, payload)
    return operator_sip_domain if browser_webphone_profile?(profile, payload)

    payload.dig(:connection, :host)
  end

  def browser_webphone_profile?(profile, payload)
    profile_availability_mode(profile, payload) == 'browser_webphone'
  end

  def profile_availability_mode(profile, payload)
    explicit_mode = profile[:availability_mode].to_s.strip.presence
    return explicit_mode if Telephony::SipProfile::AVAILABILITY_MODES.include?(explicit_mode)

    default_profile_availability_mode(payload[:provider_kind])
  end

  def operator_sip_domain
    ENV.fetch('TELEPHONY_VIRTUAL_PBX_OPERATOR_DOMAIN', DEFAULT_OPERATOR_SIP_DOMAIN).presence || DEFAULT_OPERATOR_SIP_DOMAIN
  end

  def ensure_inbox_members_for_profiles!(inbox, payload)
    Array.wrap(payload[:profiles]).filter_map { |profile| profile[:user_id].presence }.uniq.each do |user_id|
      inbox.inbox_members.find_or_create_by!(user_id: user_id)
    end
  end

  def number_ref_taken?(payload, exclude_inbox_id: nil)
    number_ref = generated_refs(payload)[:number_ref]
    return false if number_ref.blank?

    scope = account.telephony_number_bindings.where(number_ref: number_ref)
    scope = scope.where.not(inbox_id: exclude_inbox_id) if exclude_inbox_id.present?
    scope.exists?
  end

  def active_calls_present?(inbox_id)
    Telephony::CallSession.active.where(account: account, inbox_id: inbox_id).exists?
  end

  def destroy_provider_connection_if_orphaned!(provider_connection)
    return if provider_connection.blank? || provider_connection.read_only?
    return if provider_connection.number_bindings.exists? || provider_connection.sip_profiles.exists?

    provider_connection.destroy!
  end

  def nullify_provisioning_run_links!(inbox:, binding: nil)
    account.telephony_provisioning_runs
           .where('inbox_id = :inbox_id OR number_binding_id = :binding_id', inbox_id: inbox.id, binding_id: binding&.id)
           .update_all(inbox_id: nil, number_binding_id: nil, provider_connection_id: nil, updated_at: Time.current)
  end

  def delete_assignment_decision_logs_for_inbox!(inbox)
    account_scope = AssignmentDecisionLog.where(account_id: account.id)
    conversation_ids = inbox.conversations.select(:id)

    account_scope
      .where(inbox_id: inbox.id)
      .or(account_scope.where(conversation_id: conversation_ids))
      .in_batches(of: 5_000, &:delete_all)
  end

  def delete_communication_thread_links_for_inbox!(inbox)
    scope = CommunicationThreadConversation.where(account_id: account.id, inbox_id: inbox.id)
    thread_ids = scope.distinct.pluck(:communication_thread_id)
    scope.delete_all
    return if thread_ids.blank?

    empty_threads = CommunicationThread
                    .where(account_id: account.id, id: thread_ids)
                    .where.missing(:communication_thread_conversations)

    empty_thread_ids = empty_threads.pluck(:id)
    return if empty_thread_ids.blank?

    Crm::Deal
      .where(account_id: account.id, originating_communication_thread_id: empty_thread_ids)
      .update_all(originating_communication_thread_id: nil, updated_at: Time.current)

    empty_threads.destroy_all
  end

  def create_steps(payload)
    refs = generated_refs(payload)
    [
      step('validate_payload', 'Validate channel, provider connection, and optional employee SIP profiles'),
      step('upsert_provider_connection', 'Upsert local provider connection/trunk ownership metadata', local_model: 'Telephony::ProviderConnection'),
      step('create_channel_voice', 'Create Channel::Voice with display_phone_number and sanitized provider_config', local_model: 'Channel::Voice'),
      step('create_inbox', 'Create inbox and attach supplied employee collaborators', local_model: 'Inbox'),
      step('create_number_binding', 'Create telephony number binding with ingress_number and deterministic number_ref',
           local_model: 'Telephony::NumberBinding', ref: refs[:number_ref]),
      step('create_routing_policy', 'Create routing policy as runtime source of truth', local_model: 'Telephony::RoutingPolicy'),
      step('upsert_sip_profiles', 'Assign supplied employee SIP profiles; profiles may still be added later in settings'),
      step('sync_remote_bridge', 'Create or update owned Fonoster/Routr resources when remote commit is requested', remote: true)
    ]
  end

  def update_steps(payload, existing_config)
    refs = generated_refs(payload)
    [
      step('load_existing_config', 'Loaded current virtual PBX bundle', inbox_id: existing_config[:inbox_id]),
      step('validate_update_payload', 'Validate editable channel, connection, profile, and routing fields'),
      step('update_local_bundle', 'Update managed local records only after ownership checks', ref: refs[:number_ref]),
      step('sync_remote_bridge', 'Create or update owned Fonoster/Routr resources when remote commit is requested', remote: true)
    ]
  end

  def delete_steps(existing_config)
    [
      step('load_existing_config', 'Loaded current virtual PBX bundle', inbox_id: existing_config[:inbox_id]),
      step('check_active_calls', 'Block deletion when active calls exist'),
      step('check_ownership', 'Delete only uniquely-owned managed resources'),
      step('delete_remote_bridge_resources', 'Delete owned Fonoster/Routr resources before local deletion when remote commit is requested',
           remote: true)
    ]
  end

  def generated_refs(payload)
    provider_kind = payload[:provider_kind]
    ingress_number = payload[:ingress_number]
    safe_ingress = remote_ref_suffix(ingress_number)
    runtime_app_ref = default_runtime_app_ref
    number_ref = if provider_kind == 'sipuni'
                   "sipuni-internal-asterisk-#{payload[:provider_account_number].presence || safe_ingress}"
                 else
                   "asterisk-analog-#{account.id}-#{safe_ingress}"
                 end

    profiles = Array.wrap(payload[:profiles])
    {
      number_ref: number_ref,
      trunk_ref: trunk_ref_for(payload, provider_kind, safe_ingress),
      credentials_ref: generated_credentials_ref(provider_kind, safe_ingress),
      app_ref: runtime_app_ref,
      runtime_app_ref: runtime_app_ref,
      profile_refs: profiles.map { |profile| "profile-#{account.id}-#{profile[:user_id]}-#{profile[:internal_extension]}" },
      profile_secret_refs: profiles.map { |profile| "cred-profile-#{account.id}-#{profile[:user_id]}-#{profile[:internal_extension]}" }
    }.compact
  end

  def trunk_ref_for(_payload, provider_kind, safe_ingress)
    return sipuni_trunk_ref if provider_kind == 'sipuni'

    "trunk-#{provider_ref_key(provider_kind)}-acct-#{account.id}-#{safe_ingress}"
  end

  def generated_credentials_ref(provider_kind, safe_ingress)
    "cred-#{provider_ref_key(provider_kind)}-acct-#{account.id}-#{safe_ingress}"
  end

  def provider_ref_key(provider_kind)
    provider_kind.to_s.tr('_', '-')
  end

  def remote_ref_suffix(value)
    normalized = value.to_s.gsub(/[^0-9A-Za-z_-]+/, '-').squeeze('-').gsub(/\A[-_]+|[-_]+\z/, '')
    normalized.presence || 'number'
  end

  def generated_refs_for(payload, existing_config)
    existing_refs = existing_config_refs(existing_config)
    if existing_refs[:number_ref].present? && same_existing_number?(payload, existing_config)
      return existing_refs.merge(
        profile_refs: generated_refs(payload)[:profile_refs],
        profile_secret_refs: generated_refs(payload)[:profile_secret_refs]
      ).compact
    end

    return generated_refs(payload) if payload[:provider_kind].present? && payload[:ingress_number].present?

    existing_refs
  end

  def same_existing_number?(payload, existing_config)
    config = (existing_config || {}).with_indifferent_access
    phone_numbers = (config[:phone_numbers] || {}).with_indifferent_access

    payload[:provider_kind].to_s == config[:provider_kind].to_s &&
      payload[:provider_account_number].to_s == phone_numbers[:provider_account_number].to_s &&
      payload[:ingress_number].to_s == phone_numbers[:ingress_number].to_s
  end

  def existing_config_refs(existing_config)
    config = (existing_config || {}).with_indifferent_access
    resources = (config[:resources] || {}).with_indifferent_access
    provider_connection = (resources[:provider_connection] || {}).with_indifferent_access

    {
      number_ref: resources[:number_ref],
      trunk_ref: resources[:trunk_ref] || provider_connection[:fonoster_trunk_ref],
      credentials_ref: provider_connection[:credentials_ref] || provider_connection[:fonoster_credentials_ref],
      app_ref: resources[:app_ref],
      runtime_app_ref: resources[:runtime_app_ref],
      profile_refs: Array.wrap(config[:profiles]).filter_map { |profile| profile.with_indifferent_access[:agent_ref] },
      profile_secret_refs: Array.wrap(config[:profiles]).filter_map { |profile| profile.with_indifferent_access[:credentials_ref] }
    }.compact
  end

  def provider_template_for(payload, existing_config)
    provider_kind = payload[:provider_kind].presence || existing_config&.dig(:provider_kind)
    return if provider_kind.blank?

    Telephony::VirtualPbx::ConfigBuilder.provider_templates[provider_kind]
  end

  def bridge_operations_for(operation, payload, existing_config: nil)
    case operation
    when 'create'
      create_bridge_operations(payload)
    when 'update'
      update_bridge_operations(payload)
    when 'delete'
      delete_bridge_operations(existing_config)
    else
      []
    end
  end

  def create_bridge_operations(payload)
    refs = generated_refs(payload)
    compact_bridge_operations([
                                trunk_bridge_operation(payload, refs, 'Upsert provider trunk'),
                                sipuni_gateway_bridge_operation(payload, refs, 'Upsert Sipuni Asterisk gateway'),
                                bridge_operation('upsert_number', 'PUT', bridge_path('/telephony/numbers/', refs[:number_ref]),
                                                 'Upsert inbound number'),
                                bridge_operation('update_number_route', 'POST', bridge_path('/telephony/numbers/', refs[:number_ref], '/route'),
                                                 'Point number route to OneLink runtime bridge'),
                                *profile_bridge_operations(payload, refs, 'PUT')
                              ])
  end

  def update_bridge_operations(payload)
    refs = generated_refs(payload)
    compact_bridge_operations([
                                trunk_bridge_operation(payload, refs, 'Upsert provider trunk metadata'),
                                sipuni_gateway_bridge_operation(payload, refs, 'Upsert Sipuni Asterisk gateway metadata'),
                                bridge_operation('upsert_number', 'PUT', bridge_path('/telephony/numbers/', refs[:number_ref]),
                                                 'Upsert inbound number metadata'),
                                bridge_operation('update_number_route', 'POST', bridge_path('/telephony/numbers/', refs[:number_ref], '/route'),
                                                 'Patch number route headers'),
                                *profile_bridge_operations(payload, refs, 'PUT')
                              ])
  end

  def delete_bridge_operations(existing_config)
    refs = existing_config_refs(existing_config)
    compact_bridge_operations([
                                *profile_delete_bridge_operations(refs),
                                delete_sipuni_gateway_bridge_operation(refs),
                                bridge_operation('delete_number', 'DELETE', bridge_path('/telephony/numbers/', refs[:number_ref]),
                                                 'Delete owned inbound number'),
                                delete_trunk_bridge_operation(refs)
                              ])
  end

  def trunk_bridge_operation(payload, refs, description)
    return if shared_internal_trunk_ref?(payload, refs)

    bridge_operation('upsert_trunk', 'PUT', bridge_path('/telephony/trunks/', refs[:trunk_ref]), description)
  end

  def sipuni_gateway_bridge_operation(payload, refs, description)
    return unless payload[:provider_kind].to_s == 'sipuni'

    bridge_operation('upsert_sipuni_gateway', 'PUT', bridge_path('/telephony/sipuni-gateways/', refs[:number_ref]), description)
  end

  def delete_trunk_bridge_operation(refs)
    return if refs[:trunk_ref].to_s == sipuni_trunk_ref

    bridge_operation('delete_trunk', 'DELETE', bridge_path('/telephony/trunks/', refs[:trunk_ref]),
                     'Delete channel-owned trunk when it is not shared')
  end

  def delete_sipuni_gateway_bridge_operation(refs)
    return if refs[:trunk_ref].to_s != sipuni_trunk_ref

    bridge_operation('delete_sipuni_gateway', 'DELETE', bridge_path('/telephony/sipuni-gateways/', refs[:number_ref]),
                     'Delete channel-owned Sipuni Asterisk gateway')
  end

  def profile_bridge_operations(payload, refs, method)
    Array.wrap(payload[:profiles]).each_with_index.filter_map do |profile, index|
      next if provider_managed_extension_profile?(payload, profile)

      bridge_operation('upsert_agent', method, bridge_path('/telephony/agents/', refs[:profile_refs][index]),
                       'Upsert employee SIP agent profile')
    end
  end

  def provider_managed_extension_profile?(payload, profile)
    provider_kind = payload[:provider_kind].to_s
    availability_mode = profile_availability_mode(profile.with_indifferent_access, payload.with_indifferent_access)

    provider_kind.in?(%w[sipuni asterisk_analog]) && PROVIDER_EXTENSION_MODES.include?(availability_mode)
  end

  def profile_delete_bridge_operations(refs)
    Array.wrap(refs[:profile_refs]).map do |profile_ref|
      bridge_operation('delete_agent', 'DELETE', bridge_path('/telephony/agents/', profile_ref),
                       'Delete employee SIP agent profile')
    end
  end

  def bridge_operation(code, method, path, description)
    {
      code: code,
      method: method,
      path: path,
      description: description,
      remote: true,
      blocked: true,
      reason: REMOTE_MUTATION_REASON
    }
  end

  def bridge_path(prefix, ref, suffix = nil)
    return if ref.blank?

    "#{prefix}#{ref}#{suffix}"
  end

  def compact_bridge_operations(operations)
    operations.compact.select { |operation| operation[:path].present? }
  end

  def sipuni_trunk_ref
    ENV.fetch('TELEPHONY_VIRTUAL_PBX_SIPUNI_TRUNK_REF', DEFAULT_SIPUNI_TRUNK_REF)
  end

  def shared_internal_trunk_ref?(payload, refs)
    payload[:provider_kind].to_s == 'sipuni' && refs[:trunk_ref].to_s == sipuni_trunk_ref
  end

  def dry_run_status(errors)
    errors.empty? ? 'dry_run_ready' : 'validation_failed'
  end

  def dry_run_warnings(existing_config)
    [].tap do |warnings|
      warnings << warning('dry_run_only', 'Fonoster/Routr/bridge writes are not executed during dry-run')
      if existing_config&.dig(
        :ownership, :read_only
      )
        warnings << warning('legacy_resource_read_only',
                            'Existing legacy resource is read-only until managed migration is approved')
      end
    end
  end

  def mutation_warnings(remote_result)
    return [] if remote_result.present?

    [warning('remote_mutation_disabled', 'Fonoster/Routr/bridge writes were not executed')]
  end

  def remote_commit_requested?(remote_commit)
    ActiveModel::Type::Boolean.new.cast(remote_commit)
  end

  def remote_result_succeeded?(remote_result)
    remote_result.present? && remote_result[:status].to_s == 'succeeded' && Array.wrap(remote_result[:errors]).empty?
  end

  def remote_plan_blocked?(plan)
    Array.wrap(plan[:operations] || plan['operations']).any? do |operation_payload|
      operation_payload.with_indifferent_access[:risk].to_s == 'blocked'
    end
  end

  def step(code, description, **metadata)
    { code: code, description: description }.merge(metadata).compact
  end

  def error(code, message)
    { code: code, message: message }
  end

  def warning(code, message)
    { code: code, message: message }
  end

  def normalize_provider_kind(value)
    value.to_s.tr('-', '_').strip.downcase
  end

  def first_present(*values)
    values.find(&:present?)
  end

  def normalize_technical_number(value)
    value.to_s.strip.sub(/\A(?:tel:)+/i, '').presence
  end

  def normalize_tel_url(value)
    normalized = normalize_technical_number(value)
    tel_url_for(normalized)
  end

  def runtime_app_ref_for(base = {}, refs = {})
    config = (base || {}).with_indifferent_access
    generated = (refs || {}).with_indifferent_access

    first_present(
      config[:runtime_app_ref],
      config[:app_ref],
      generated[:runtime_app_ref],
      generated[:app_ref],
      default_runtime_app_ref
    )
  end

  def default_runtime_app_ref
    first_present(
      ENV.fetch('TELEPHONY_BRIDGE_RUNTIME_APP_REF', nil),
      ENV.fetch('TELEPHONY_BRIDGE_DEFAULT_APP_REF', nil)
    )
  end

  def tel_url_for(value)
    value.present? ? "tel:#{value}" : nil
  end
end
