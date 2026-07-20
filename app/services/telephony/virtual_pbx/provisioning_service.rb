# frozen_string_literal: true

require 'cgi'

class Telephony::VirtualPbx::ProvisioningService
  ALLOWED_PROVIDER_KINDS = %w[asterisk_analog sipuni binotel].freeze
  DEFAULT_ROUTE_MODE = 'operator'
  DEFAULT_FALLBACK_MODE = 'reject'
  DEFAULT_OPERATOR_DISTRIBUTION_MODE = Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_BROADCAST
  MANAGED_BY_ONELINK = 'onelink'
  LOCAL_OWNERSHIP_STATUS = 'local'
  REMOTE_MUTATION_REASON = 'REMOTE_MUTATION_REQUIRES_APPROVAL'
  DEFAULT_OPERATOR_SIP_DOMAIN = 'operator.cloud.vconsult.kz'
  DEFAULT_ASTERISK_ANALOG_OUTBOUND_DIAL_FORMAT = 'kz_trunk'
  PROVIDER_OWNED_ROUTING_KINDS = %w[asterisk_analog sipuni binotel].freeze
  LOCAL_NATIVE_PROVIDER_KINDS = %w[asterisk_analog sipuni binotel].freeze
  LEGACY_PROVIDER_CONFIG_KEYS = %i[
    app_ref
    runtime_app_ref
    trunk_ref
    fonoster_tel_url
    fonoster_number_ref
    operator_agent_ref
  ].freeze

  def initialize(account:, current_user:)
    @account = account
    @current_user = current_user
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
    plan = local_provisioning_plan(status: config[:ready] ? 'ready' : 'action_required')

    product_payload(
      operation: 'readiness_check',
      config: config,
      include_diagnostics: include_diagnostics,
      extra: {
        remote_commit: false,
        mutation_allowed: false,
        ready: config[:ready],
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
    steps = operation.to_s == 'delete' ? delete_steps(config) : update_steps({}, config)
    plan = local_provisioning_plan(steps: steps)

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

  # Keep remote_commit in the public service contract while remote mutations remain fail-closed.
  def provision(inbox_id:, remote_commit: false, include_diagnostics: false) # rubocop:disable Lint/UnusedMethodArgument
    config = config_builder.for_inbox(inbox_id)
    plan = local_provisioning_plan(steps: update_steps({}, config))

    product_payload(
      operation: 'provision',
      config: config_builder.for_inbox(inbox_id),
      include_diagnostics: include_diagnostics,
      extra: {
        status: 'local_only',
        remote_commit: false,
        mutation_allowed: false,
        remote_mutation_allowed: false,
        remote_mutation_reason: REMOTE_MUTATION_REASON,
        provisioning_plan: product_plan(plan),
        warnings: config[:warnings]
      }
    )
  end

  def reconcile(inbox_id:, include_diagnostics: false)
    config = config_builder.for_inbox(inbox_id)
    reconciliation = {
      status: config[:ready] ? 'ready' : 'action_required',
      drift: [],
      checked_at: Time.current.iso8601
    }

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
    remote_commit = remote_commit_for(normalized[:provider_kind], remote_commit)
    errors = validation_errors(normalized, require_profiles: normalized[:profiles_supplied])

    if dry_run || errors.any?
      return dry_run_payload(operation: 'create', normalized_payload: normalized, errors: errors, existing_config: nil,
                             steps: create_steps(normalized), include_diagnostics: include_diagnostics)
    end

    mutation_result = create_local_channel!(normalized)
    payload = mutation_payload(
      'create',
      mutation_result,
      normalized,
      create_steps(normalized),
      remote_commit: remote_commit,
      include_diagnostics: include_diagnostics
    )
    broadcast_webphone_config_changed!('create', mutation_result, normalized)
    payload
  end

  def update_channel(inbox_id:, payload:, dry_run: true, remote_commit: false, include_diagnostics: false)
    existing_config = config_builder.for_inbox(inbox_id)
    expected_configuration_version = payload.to_h.with_indifferent_access[:expected_configuration_version]
    normalized = normalize_payload(payload, fallback: existing_config)
    remote_commit = remote_commit_for(normalized[:provider_kind] || existing_config[:provider_kind], remote_commit)
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
    if block_update_for_active_calls?(inbox_id, payload)
      errors << error('active_calls_present', 'Channel has active calls and cannot be updated')
    end

    if dry_run || errors.any?
      return dry_run_payload(operation: 'update', normalized_payload: normalized, errors: errors, existing_config: existing_config,
                             steps: update_steps(normalized, existing_config), include_diagnostics: include_diagnostics)
    end

    verify_configuration_version!(existing_config, expected_configuration_version)
    mutation_result = update_local_channel!(inbox_id, normalized, expected_configuration_version)
    payload = mutation_payload(
      'update',
      mutation_result,
      normalized,
      update_steps(normalized, existing_config),
      remote_commit: remote_commit,
      include_diagnostics: include_diagnostics,
      existing_config: existing_config
    )
    broadcast_webphone_config_changed!('update', mutation_result, normalized)
    payload
  end

  def delete_channel(inbox_id:, confirm: false, dry_run: true, remote_commit: false, include_diagnostics: false)
    existing_config = config_builder.for_inbox(inbox_id)
    remote_commit = remote_commit_for(existing_config[:provider_kind], remote_commit)
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

    plan = local_provisioning_plan(steps: delete_steps(existing_config))

    mutation_result = delete_local_channel!(inbox_id)
    payload = mutation_payload(
      'delete',
      mutation_result,
      { inbox_id: inbox_id, confirm: confirm },
      delete_steps(existing_config),
      existing_config: existing_config,
      prebuilt_plan: plan,
      remote_result: nil,
      remote_commit: remote_commit,
      include_diagnostics: include_diagnostics
    )
    broadcast_webphone_config_changed!('delete', mutation_result, existing_config)
    payload
  end

  private

  attr_reader :account, :current_user, :config_builder

  def verify_configuration_version!(config, expected_version)
    return if expected_version.blank?

    current_version = config[:configuration_version]
    if current_version.present? &&
       ActiveSupport::SecurityUtils.secure_compare(expected_version.to_s, current_version.to_s)
      return
    end

    raise Telephony::Error.new(
      code: 'VIRTUAL_PBX_CONFIGURATION_STALE',
      message: 'Virtual PBX configuration changed; reload it before saving',
      status: :conflict,
      details: { expected_configuration_version: expected_version, current_configuration_version: current_version }
    )
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
        attrs.slice(:key, :description, :risk, :owned, :shared, :conflict, :remote)
      end
      copy[:operations] = operations
      copy[:items] = product_plan_items(operations)
      copy.delete(:conflicts) if copy[:conflicts].blank?
    end
  end

  def product_plan_items(operations)
    requires_remote = operations.any? { |operation| operation.with_indifferent_access[:remote] }
    remote_status = requires_remote ? 'requires_remote_commit' : 'ready'

    [
      { code: 'validate_settings', status: 'ready' },
      { code: 'save_channel', status: 'ready' },
      { code: 'connect_number', status: remote_status },
      { code: 'configure_routing', status: remote_status },
      { code: 'remote_sync', status: remote_status }
    ]
  end

  # Keep steps in the plan-builder contract until remote operations are enabled.
  def local_provisioning_plan(steps: [], status: 'local_only') # rubocop:disable Lint/UnusedMethodArgument
    {
      status: status,
      remote_mutations: 'disabled',
      operations: []
    }
  end

  def dry_run_payload(operation:, normalized_payload:, errors:, existing_config:, steps:, include_diagnostics: false)
    sanitized_payload = Telephony::VirtualPbx::ConfigBuilder.sanitize(normalized_payload)
    plan = local_provisioning_plan(steps: steps, status: dry_run_status(errors))

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
      warnings: dry_run_warnings(existing_config, normalized_payload)
    }.compact

    if include_diagnostics
      payload[:diagnostics] = {
        payload: sanitized_payload,
        provider_template: provider_template_for(normalized_payload, existing_config),
        generated_refs: generated_refs_for(normalized_payload, existing_config),
        existing_config: existing_config
      }.compact
    end

    payload
  end

  # Keep remote_commit accepted while mutations are intentionally local-only.
  def mutation_payload(operation, mutation_result, normalized_payload, steps, existing_config: nil, prebuilt_plan: nil, remote_result: nil,
                       remote_commit: false, include_diagnostics: false) # rubocop:disable Lint/UnusedMethodArgument
    config = mutation_result[:inbox_id].present? ? config_builder.for_inbox(mutation_result[:inbox_id]) : nil
    plan = prebuilt_plan || local_provisioning_plan(steps: steps)

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
      remote_mutation_allowed: false,
      remote_mutation_reason: remote_result.present? ? nil : REMOTE_MUTATION_REASON,
      mutation_reason: 'local_janus_sip_commit',
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
      warnings: mutation_warnings(remote_result, normalized_payload[:provider_kind] || config&.dig(:provider_kind))
    }.compact

    if include_diagnostics
      payload[:diagnostics] = {
        payload: Telephony::VirtualPbx::ConfigBuilder.sanitize(normalized_payload),
        provider_template: provider_template_for(normalized_payload, existing_config),
        generated_refs: generated_refs_for(normalized_payload, existing_config),
        config: config
      }.compact
    end

    payload
  end

  def normalize_payload(payload, fallback: nil)
    source = payload.to_h.deep_stringify_keys
    fallback_phone_numbers = fallback&.fetch(:phone_numbers, {}) || {}
    fallback_routing = fallback&.fetch(:routing, {}) || {}
    fallback_metadata = fallback&.fetch(:metadata, {}) || {}

    provider_kind = normalize_provider_kind(source['provider_kind'].presence || fallback&.dig(:provider_kind))
    ingress_number = normalize_technical_number(
      first_present(
        source['ingress_number'],
        source['sipuni_ingress_number'],
        source['binotel_ingress_number'],
        source['provider_number'],
        fallback_phone_numbers[:ingress_number]
      )
    )
    provider_account_number = normalize_technical_number(
      first_present(
        source['provider_account_number'],
        source['sipuni_account_number'],
        source['binotel_account_number'],
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
      connection: normalize_connection(
        source['connection'] || {},
        provider_kind,
        fallback&.dig(:resources, :provider_connection)
      ),
      profiles: profiles_supplied ? normalize_profiles(source['profiles']) : normalize_existing_profiles(fallback&.dig(:profiles)),
      profiles_supplied: profiles_supplied,
      routing: normalize_routing(source['routing'] || {}, fallback_routing, profiles_supplied: profiles_supplied),
      metadata: normalize_metadata(fallback_metadata.to_h.deep_stringify_keys.merge(source['metadata'].to_h.deep_stringify_keys))
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
    return false unless PROVIDER_OWNED_ROUTING_KINDS.include?(provider_kind.to_s)

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
      profile_kind = normalized_profile_kind(attrs['profile_kind'])
      normalized = {
        id: attrs['id'].presence&.to_i,
        profile_kind: profile_kind,
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
        id: attrs[:id],
        profile_kind: normalized_profile_kind(attrs[:profile_kind]),
        user_id: attrs[:user_id],
        internal_extension: attrs[:internal_extension],
        sip_username: attrs[:sip_username],
        sip_password_configured: ActiveModel::Type::Boolean.new.cast(attrs[:sip_password_configured]),
        availability_mode: attrs[:availability_mode],
        enabled: attrs.key?(:enabled) ? attrs[:enabled] : true
      }.compact
    end
  end

  def normalized_profile_kind(value)
    candidate = value.to_s.strip.downcase.presence
    return candidate if Telephony::SipProfile::PROFILE_KINDS.include?(candidate)

    Telephony::SipProfile::PROFILE_KIND_HUMAN_OPERATOR
  end

  def profile_with_default_availability_mode(profile, payload)
    return profile if profile[:availability_mode].present?

    profile.merge(availability_mode: default_profile_availability_mode(payload[:provider_kind]))
  end

  def default_profile_availability_mode(provider_kind)
    return 'browser_webphone' if local_native_provider_kind?(provider_kind)

    'external_extension'
  end

  def normalize_routing(source, fallback, profiles_supplied: false)
    source = source.to_h.deep_stringify_keys

    {
      mode: source['mode'].presence || fallback[:mode] || DEFAULT_ROUTE_MODE,
      fallback_mode: source['fallback_mode'].presence || fallback[:fallback_mode] || DEFAULT_FALLBACK_MODE,
      ai_enabled: normalized_routing_ai_enabled(source, fallback),
      operator_distribution_mode: normalized_operator_distribution_mode(source, fallback),
      show_calls_handled_by_other_operators: normalized_show_calls_handled_by_other_operators(source, fallback),
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

  def normalized_show_calls_handled_by_other_operators(source, fallback)
    value = if source.key?('show_calls_handled_by_other_operators')
              source['show_calls_handled_by_other_operators']
            else
              fallback[:show_calls_handled_by_other_operators]
            end

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def normalized_operator_agent_aor(source, fallback, profiles_supplied: false)
    return source['operator_agent_aor'].presence if source.key?('operator_agent_aor')
    return nil if profiles_supplied

    fallback[:operator_agent_aor]
  end

  def normalize_metadata(source)
    source = source.to_h.deep_stringify_keys
    metadata = source.slice('environment', 'source', 'notes', 'outbound_dial_format')
    outbound_dial_format = first_present(
      metadata['outbound_dial_format'],
      source['outboundDialFormat'],
      source['dial_format'],
      source['dialFormat']
    )
    metadata['outbound_dial_format'] = outbound_dial_format if outbound_dial_format.present?
    metadata
  end

  def validation_errors(payload, require_profiles: true, profile_inbox_id: nil, check_duplicate_number_ref: true, exclude_inbox_id: nil)
    [].tap do |errors|
      unless payload[:provider_kind].in?(ALLOWED_PROVIDER_KINDS)
        errors << error('provider_kind_invalid',
                        'provider_kind must be asterisk_analog, sipuni, or binotel')
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
      errors.concat(profile_errors(payload[:profiles], inbox_id: profile_inbox_id)) if require_profiles
    end
  end

  def connection_port_invalid_error
    error('connection_port_invalid', 'connection.port must be an integer between 1 and 65535')
  end

  def profile_errors(profiles, inbox_id: nil)
    voice_agent_count = Array.wrap(profiles).count { |profile| voice_agent_profile?(profile) }
    errors = Array.wrap(profiles).each_with_index.with_object([]) do |(profile, index), profile_errors|
      unless Telephony::SipProfile::PROFILE_KINDS.include?(profile[:profile_kind].to_s)
        profile_errors << error('profile_kind_invalid', "profiles[#{index}].profile_kind is invalid")
      end
      if human_operator_profile?(profile) && profile[:user_id].blank?
        profile_errors << error('profile_user_required', "profiles[#{index}].user_id is required")
      end
      if voice_agent_profile?(profile) && profile[:user_id].present?
        profile_errors << error('profile_voice_agent_user_forbidden', "profiles[#{index}].user_id must be blank for voice agent profiles")
      end
      if profile[:internal_extension].blank?
        profile_errors << error('profile_internal_extension_required',
                                "profiles[#{index}].internal_extension is required")
      end
      if voice_agent_profile?(profile) && profile[:sip_username].blank?
        profile_errors << error('profile_voice_agent_sip_username_required', "profiles[#{index}].sip_username is required for voice agent profiles")
      end
      if sip_credentials_pair_invalid?(profile, inbox_id: inbox_id)
        profile_errors << error('profile_sip_credentials_pair_required', "profiles[#{index}] SIP username/password must be provided together")
      end
      if profile[:availability_mode].present? && Telephony::SipProfile::AVAILABILITY_MODES.exclude?(profile[:availability_mode].to_s)
        profile_errors << error('profile_availability_mode_invalid', "profiles[#{index}].availability_mode is invalid")
      end
      next if voice_agent_profile?(profile)
      next if profile[:user_id].blank?

      unless account.account_users.exists?(user_id: profile[:user_id])
        profile_errors << error('profile_user_not_in_account', "profiles[#{index}].user_id must belong to the account")
        next
      end

      next if inbox_id.blank? || InboxMember.exists?(inbox_id: inbox_id, user_id: profile[:user_id])

      profile_errors << error('profile_user_not_in_inbox', "profiles[#{index}].user_id must be an inbox collaborator before SIP assignment")
    end
    return errors unless voice_agent_count > 1

    errors << error('profile_voice_agent_unique_per_inbox', 'Only one voice agent SIP profile is allowed per inbox')
    errors
  end

  def sip_credentials_pair_invalid?(profile, inbox_id: nil)
    has_username = profile[:sip_username].present?
    has_password = profile[:sip_password].present?
    return !existing_sip_profile_password_configured?(profile, inbox_id: inbox_id) if voice_agent_profile?(profile) && has_username && !has_password
    return has_password unless has_username
    return false if has_password

    !existing_sip_profile_password_configured?(profile, inbox_id: inbox_id)
  end

  def existing_sip_profile_password_configured?(profile, inbox_id: nil)
    return false if inbox_id.blank? || profile[:internal_extension].blank?

    existing_profile = existing_sip_profile_for_credentials(profile, inbox_id: inbox_id)
    existing_profile ||= reusable_sip_profile_credentials_for(profile, inbox_id: inbox_id)
    return false if existing_profile.blank? || existing_profile.password_secret_ref.blank?

    existing_profile.sip_username.to_s == profile[:sip_username].to_s
  end

  def existing_sip_profile_for_credentials(profile, inbox_id:)
    explicit_profile = sip_profile_record_by_id(account.inboxes.find_by(id: inbox_id), profile[:id])
    return explicit_profile if explicit_profile.present?

    if voice_agent_profile?(profile)
      voice_agent_profile_for_inbox(inbox_id) ||
        account.telephony_sip_profiles.find_by(
          inbox_id: inbox_id,
          internal_extension: profile[:internal_extension],
          sip_username: profile[:sip_username]
        )
    elsif profile[:user_id].present?
      account.telephony_sip_profiles.find_by(
        inbox_id: inbox_id,
        user_id: profile[:user_id],
        internal_extension: profile[:internal_extension]
      )
    end
  end

  def reusable_sip_profile_credentials_for(profile, inbox_id:)
    return if inbox_id.blank? || profile[:internal_extension].blank? || profile[:sip_username].blank?
    return if voice_agent_profile?(profile)

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
      channel = Channel::Voice.create!(
        account: account,
        phone_number: payload[:display_phone_number],
        provider: voice_provider_for(payload[:provider_kind]),
        provider_config: provider_config_for(payload, provider_connection, refs: refs)
      )
      inbox = Inbox.create!(account: account, channel: channel, name: payload[:channel_name])
      ensure_inbox_members_for_profiles!(inbox, payload)
      binding = upsert_number_binding!(inbox, channel, payload, provider_connection, refs: refs)
      upsert_routing_policy!(binding, payload)
      stale_sip_profiles = upsert_sip_profiles!(inbox, provider_connection, payload) if payload[:profiles_supplied]
      result = {
        inbox_id: inbox.id,
        provider: channel.provider,
        sip_profile_ids: inbox.telephony_sip_profiles.pluck(:id),
        webphone_config_changed_user_ids: inbox.telephony_sip_profiles.pluck(:user_id).compact,
        stale_sip_profiles: stale_sip_profiles
      }
    end
    result
  end

  def update_local_channel!(inbox_id, payload, expected_configuration_version)
    result = nil
    ActiveRecord::Base.transaction do
      inbox = account.inboxes.find(inbox_id)
      channel = inbox.channel
      inbox.lock!
      channel.lock!
      binding = inbox.telephony_number_binding
      previous_user_ids = inbox.telephony_sip_profiles.pluck(:user_id).compact
      previous_sip_profile_ids = inbox.telephony_sip_profiles.pluck(:id)
      existing_config = config_builder.for_inbox(inbox_id)
      verify_configuration_version!(existing_config, expected_configuration_version)
      refs = generated_refs_for(payload, existing_config)
      provider_connection = upsert_provider_connection!(payload, existing: binding&.provider_connection, refs: refs)

      inbox.update!(name: payload[:channel_name])
      channel.update!(phone_number: payload[:display_phone_number],
                      provider: voice_provider_for(payload[:provider_kind]),
                      provider_config: provider_config_for(payload, provider_connection, channel.provider_config_hash, refs: refs))
      binding = upsert_number_binding!(inbox, channel, payload, provider_connection, refs: refs)
      upsert_routing_policy!(binding, payload)
      upsert_sip_profiles!(inbox, provider_connection, payload) if payload[:profiles_supplied]
      current_user_ids = inbox.telephony_sip_profiles.pluck(:user_id).compact
      result = {
        inbox_id: inbox.id,
        provider: channel.provider,
        sip_profile_ids: (previous_sip_profile_ids + inbox.telephony_sip_profiles.pluck(:id)).uniq,
        webphone_config_changed_user_ids: (previous_user_ids + current_user_ids).uniq
      }
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
      provider = inbox.channel&.provider
      affected_user_ids = inbox.telephony_sip_profiles.pluck(:user_id).compact
      sip_profile_ids = inbox.telephony_sip_profiles.pluck(:id)

      nullify_provisioning_run_links!(inbox: inbox, binding: binding)
      delete_assignment_decision_logs_for_inbox!(inbox)
      delete_communication_thread_links_for_inbox!(inbox)
      inbox.telephony_sip_profiles.destroy_all
      inbox.destroy!
      destroy_provider_connection_if_orphaned!(provider_connection)
      result = {
        deleted: true,
        deleted_inbox_id: deleted_inbox_id,
        provider: provider,
        sip_profile_ids: sip_profile_ids,
        webphone_config_changed_user_ids: affected_user_ids
      }
    end
    result
  end

  def broadcast_webphone_config_changed!(operation, mutation_result, config)
    tokens = account.users.where(id: mutation_result[:webphone_config_changed_user_ids]).filter_map(&:pubsub_token).uniq
    return if tokens.blank?

    payload = { event: 'telephony.webphone_config_changed', data: webphone_config_changed_payload(operation, mutation_result, config) }

    tokens.each { |token| ActionCable.server.broadcast(token, payload) }
  rescue StandardError => e
    Rails.logger.warn(
      'TELEPHONY_WEBPHONE_CONFIG_CHANGED_BROADCAST_FAILED ' \
      "account_id=#{account.id} operation=#{operation} error=#{e.class.name}: #{e.message}"
    )
  end

  def webphone_config_changed_payload(operation, mutation_result, config)
    {
      account_id: account.id,
      operation: operation,
      inbox_id: mutation_result[:inbox_id] || mutation_result[:deleted_inbox_id],
      provider: mutation_result[:provider] || config&.dig(:provider_kind),
      sip_profile_ids: mutation_result[:sip_profile_ids],
      webphone_config_version: webphone_config_version_for(mutation_result[:sip_profile_ids]),
      reason: 'virtual_pbx_channel_changed'
    }.compact
  end

  def webphone_config_version_for(sip_profile_ids)
    versions = account.telephony_sip_profiles
                      .where(id: Array.wrap(sip_profile_ids))
                      .order(:id)
                      .select(:id, :metadata)
    versions.map { |profile| "#{profile.id}:#{profile.registration_config_version}" }.join('|').presence
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
      fonoster_credentials_ref: nil,
      fonoster_trunk_ref: nil,
      send_register: ActiveModel::Type::Boolean.new.cast(payload.dig(:connection, :send_register)),
      status: 'active',
      managed_by: MANAGED_BY_ONELINK,
      ownership_status: LOCAL_OWNERSHIP_STATUS,
      metadata: provider_connection_metadata(payload, connection),
      updated_by: current_user
    )
    connection.created_by ||= current_user if connection.new_record?
    connection.save!
    connection
  end

  def provider_connection_metadata(payload, connection)
    existing_metadata = connection.metadata.to_h.with_indifferent_access
    metadata = existing_metadata.merge((payload[:metadata] || {}).to_h.with_indifferent_access)
    return metadata unless payload[:provider_kind].to_s == 'asterisk_analog'

    if metadata[:outbound_dial_format].blank? && existing_metadata[:outbound_dial_format].present?
      metadata[:outbound_dial_format] = existing_metadata[:outbound_dial_format]
    end
    metadata[:outbound_dial_format] = DEFAULT_ASTERISK_ANALOG_OUTBOUND_DIAL_FORMAT if metadata[:outbound_dial_format].blank?
    metadata
  end

  def provider_connection_credentials_ref(payload, refs)
    first_present(
      payload.dig(:connection, :credentials_ref),
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
      provider: channel.provider,
      number_ref: refs[:number_ref],
      phone_number: payload[:ingress_number],
      display_phone_number: payload[:display_phone_number],
      provider_account_number: payload[:provider_account_number],
      ingress_number: payload[:ingress_number],
      fonoster_tel_url: nil,
      app_ref: nil,
      trunk_ref: nil,
      provider_connection: provider_connection,
      managed_by: MANAGED_BY_ONELINK,
      ownership_status: LOCAL_OWNERSHIP_STATUS,
      metadata: binding.metadata.to_h.merge(payload[:metadata]).merge(
        provider_kind: payload[:provider_kind],
        source: payload.dig(:metadata, 'source')
      ).compact,
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
        profile_kind: profile[:profile_kind],
        user_id: human_operator_profile?(profile) ? profile[:user_id] : nil,
        internal_extension: profile[:internal_extension],
        provider_connection: provider_connection,
        sip_username: sip_username,
        sip_password: profile[:sip_password].presence || profile_record.sip_password,
        password_secret_ref: password_secret_ref_for(profile_record, profile, payload, index, sip_username: sip_username),
        sip_host: profile_sip_host(profile, payload),
        agent_ref: agent_ref,
        agent_aor: generated_profile_aor(profile, payload),
        fonoster_agent_ref: nil,
        credentials_ref: credentials_ref,
        fonoster_credentials_ref: nil,
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

  def sip_profile_cleanup_snapshot(profile_record)
    return if profile_record.blank?

    {
      id: profile_record.id,
      user_id: profile_record.user_id,
      internal_extension: profile_record.internal_extension,
      sip_username: profile_record.sip_username,
      agent_ref: profile_record.agent_ref,
      local_agent_ref: profile_record.agent_ref,
      credentials_ref: profile_record.credentials_ref,
      local_credentials_ref: profile_record.credentials_ref,
      availability_mode: profile_record.availability_mode,
      status: profile_record.status,
      enabled: profile_record.enabled
    }.compact
  end

  def stale_sip_profile_cleanup_required?(previous_profile, profile_record)
    return false if previous_profile.blank?

    previous_profile[:agent_ref].to_s != profile_record.agent_ref.to_s ||
      previous_profile[:credentials_ref].to_s != profile_record.credentials_ref.to_s ||
      previous_profile[:sip_username].to_s != profile_record.sip_username.to_s ||
      previous_profile[:internal_extension].to_s != profile_record.internal_extension.to_s
  end

  def sip_profile_record_for(inbox, profile)
    explicit_profile = sip_profile_record_by_id(inbox, profile[:id])
    return explicit_profile if explicit_profile.present?

    if voice_agent_profile?(profile)
      return voice_agent_profile_for_inbox(inbox.id) ||
             voice_agent_convertible_profile_for(inbox, profile) ||
             account.telephony_sip_profiles.new(inbox: inbox, profile_kind: Telephony::SipProfile::PROFILE_KIND_VOICE_AGENT)
    end

    exact_profile = account.telephony_sip_profiles.find_by(
      inbox: inbox,
      profile_kind: Telephony::SipProfile::PROFILE_KIND_HUMAN_OPERATOR,
      user_id: profile[:user_id],
      internal_extension: profile[:internal_extension]
    )
    return exact_profile if exact_profile.present?

    extension_profile = reassignable_sip_profile_for(inbox, profile)
    return extension_profile if extension_profile.present?

    if sip_credentials_omitted?(profile)
      existing_profiles = account.telephony_sip_profiles.human_operator.where(inbox: inbox, user_id: profile[:user_id])
      return existing_profiles.first if existing_profiles.one?
    end

    account.telephony_sip_profiles.new(
      inbox: inbox,
      profile_kind: Telephony::SipProfile::PROFILE_KIND_HUMAN_OPERATOR,
      user_id: profile[:user_id],
      internal_extension: profile[:internal_extension]
    )
  end

  def sip_profile_record_by_id(inbox, profile_id)
    return if inbox.blank? || profile_id.blank?

    account.telephony_sip_profiles.find_by(id: profile_id, inbox: inbox)
  end

  def voice_agent_profile_for_inbox(inbox_id)
    account.telephony_sip_profiles.find_by(
      inbox_id: inbox_id,
      profile_kind: Telephony::SipProfile::PROFILE_KIND_VOICE_AGENT
    )
  end

  def voice_agent_convertible_profile_for(inbox, profile)
    by_extension = account.telephony_sip_profiles.find_by(
      inbox: inbox,
      internal_extension: profile[:internal_extension]
    )
    return by_extension if by_extension.present?

    return if profile[:sip_username].blank?

    account.telephony_sip_profiles.find_by(
      inbox: inbox,
      sip_username: profile[:sip_username]
    )
  end

  def reassignable_sip_profile_for(inbox, profile)
    return if inbox.blank? || profile[:internal_extension].blank?

    existing_profiles = account.telephony_sip_profiles.human_operator.where(inbox: inbox, internal_extension: profile[:internal_extension]).to_a
    return unless existing_profiles.one?

    existing_profiles.first
  end

  def sip_credentials_omitted?(profile)
    !profile.key?(:sip_username) && !profile.key?(:sip_password)
  end

  def provider_config_for(payload, provider_connection, base = {}, refs: generated_refs(payload))
    config = base.with_indifferent_access.merge(
      provider_kind: payload[:provider_kind],
      number_ref: refs[:number_ref],
      display_phone_number: payload[:display_phone_number],
      provider_account_number: payload[:provider_account_number],
      ingress_number: payload[:ingress_number],
      routing_mode: payload.dig(:routing, :mode),
      fallback_mode: payload.dig(:routing, :fallback_mode),
      operator_distribution_mode: payload.dig(:routing, :operator_distribution_mode),
      show_calls_handled_by_other_operators: payload.dig(:routing, :show_calls_handled_by_other_operators),
      operator_agent_aor: operator_agent_aor_for(payload),
      provider_connection_id: provider_connection.id,
      managed_by: MANAGED_BY_ONELINK,
      ownership_status: LOCAL_OWNERSHIP_STATUS,
      source: payload.dig(:metadata, 'source') || payload[:provider_kind]
    )

    config.except!(*LEGACY_PROVIDER_CONFIG_KEYS)

    config.compact
  end

  def provider_connection_name(payload, refs: generated_refs(payload))
    first_present(refs[:number_ref], payload[:channel_name], payload[:provider_kind])
  end

  def voice_provider_for(provider_kind)
    provider_kind = provider_kind.to_s
    return provider_kind if local_native_provider_kind?(provider_kind)

    nil
  end

  def operator_agent_aor_for(payload)
    explicit_target = payload.dig(:routing, :operator_agent_aor).presence
    return explicit_target if explicit_target.present?
    return unless payload.dig(:routing, :operator_distribution_mode) == Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_TARGETED

    generated_profile_aor(Array.wrap(payload[:profiles]).first || {}, payload)
  end

  def generated_profile_aor(profile, payload)
    if local_native_provider_kind?(payload[:provider_kind])
      username = profile[:sip_username].presence || profile[:internal_extension].presence || 'operator'
      host = payload.dig(:connection, :host).presence || 'voice.local'
      return "sip:#{username}@#{host}"
    end

    extension = profile[:internal_extension].presence || 'operator'
    host = browser_webphone_profile?(profile, payload) ? operator_sip_domain : payload.dig(:connection, :host).presence || 'voice.local'
    "sip:#{extension}@#{host}"
  end

  def profile_sip_host(profile, payload)
    return payload.dig(:connection, :host) if local_native_provider_kind?(payload[:provider_kind])
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
    Array.wrap(payload[:profiles]).filter_map { |profile| profile[:user_id].presence if human_operator_profile?(profile) }.uniq.each do |user_id|
      inbox.inbox_members.find_or_create_by!(user_id: user_id)
    end
  end

  def human_operator_profile?(profile)
    profile[:profile_kind].to_s == Telephony::SipProfile::PROFILE_KIND_HUMAN_OPERATOR
  end

  def voice_agent_profile?(profile)
    profile[:profile_kind].to_s == Telephony::SipProfile::PROFILE_KIND_VOICE_AGENT
  end

  def number_ref_taken?(payload, exclude_inbox_id: nil)
    number_ref = generated_refs(payload)[:number_ref]
    return false if number_ref.blank?

    scope = account.telephony_number_bindings.where(number_ref: number_ref)
    scope = scope.where.not(inbox_id: exclude_inbox_id) if exclude_inbox_id.present?
    scope.exists?
  end

  def active_calls_present?(inbox_id)
    Telephony::CallSession.active.where(account: account, inbox_id: inbox_id).any? do |call_session|
      !resolved_logical_call?(call_session)
    end
  end

  def block_update_for_active_calls?(inbox_id, payload)
    !handled_call_visibility_only_update?(payload) && active_calls_present?(inbox_id)
  end

  def resolved_logical_call?(call_session)
    return false unless call_session.direction == 'inbound'
    return false unless call_session.canonical_status.in?(%w[created ringing connecting])
    return false if call_session.answered_at.present?

    call_session.logical_group_sessions.any? do |related_call_session|
      next false if related_call_session.id == call_session.id
      next false unless related_call_session.terminal?

      operator_claim = related_call_session.metadata.to_h['operator_claim']
      related_call_session.answered_at.present? || operator_claim.present?
    end
  end

  def handled_call_visibility_only_update?(payload)
    update_payload = payload.to_h.with_indifferent_access
    return false if (update_payload.keys.map(&:to_s) - %w[expected_configuration_version routing]).any?

    routing = update_payload[:routing]
    return false unless routing.respond_to?(:to_h)

    routing.to_h.keys.map(&:to_s) == ['show_calls_handled_by_other_operators']
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
      step('upsert_sip_profiles', 'Assign supplied employee SIP profiles; profiles may still be added later in settings')
    ]
  end

  def update_steps(payload, existing_config)
    refs = generated_refs(payload)
    [
      step('load_existing_config', 'Loaded current virtual PBX bundle', inbox_id: existing_config[:inbox_id]),
      step('validate_update_payload', 'Validate editable channel, connection, profile, and routing fields'),
      step('update_local_bundle', 'Update managed local records only after ownership checks', ref: refs[:number_ref])
    ]
  end

  def delete_steps(existing_config)
    [
      step('load_existing_config', 'Loaded current virtual PBX bundle', inbox_id: existing_config[:inbox_id]),
      step('check_active_calls', 'Block deletion when active calls exist'),
      step('check_ownership', 'Delete only uniquely-owned managed resources')
    ]
  end

  def generated_refs(payload)
    provider_kind = payload[:provider_kind]
    ingress_number = payload[:ingress_number]
    safe_ingress = ref_suffix(ingress_number)
    number_scope = payload[:provider_account_number].presence || safe_ingress
    number_ref = if provider_kind.in?(PROVIDER_OWNED_ROUTING_KINDS)
                   "#{provider_ref_key(provider_kind)}-sip-device-#{ref_scope_suffix(payload, number_scope)}"
                 else
                   "asterisk-analog-#{account.id}-#{safe_ingress}"
                 end

    profiles = Array.wrap(payload[:profiles])
    refs = {
      number_ref: number_ref,
      credentials_ref: generated_credentials_ref(payload, provider_kind, safe_ingress),
      profile_refs: profiles.map { |profile| "profile-#{account.id}-#{profile_ref_token(profile)}-#{profile[:internal_extension]}" },
      profile_secret_refs: profiles.map { |profile| "cred-profile-#{account.id}-#{profile_ref_token(profile)}-#{profile[:internal_extension]}" }
    }
    refs.compact
  end

  def profile_ref_token(profile)
    return 'voice-agent' if voice_agent_profile?(profile)

    profile[:user_id]
  end

  def generated_credentials_ref(payload, provider_kind, safe_ingress)
    return "cred-#{provider_ref_key(provider_kind)}-#{ref_scope_suffix(payload, safe_ingress)}" if provider_kind.in?(PROVIDER_OWNED_ROUTING_KINDS)

    "cred-#{provider_ref_key(provider_kind)}-acct-#{account.id}-#{safe_ingress}"
  end

  def ref_scope_suffix(payload, fallback_suffix)
    safe_host = payload.dig(:connection, :host).presence
    parts = ["acct-#{account.id}"]
    parts << ref_suffix(safe_host) if safe_host.present?
    parts << ref_suffix(fallback_suffix)
    parts.join('-')
  end

  def provider_ref_key(provider_kind)
    provider_kind.to_s.tr('_', '-')
  end

  def ref_suffix(value)
    normalized = value.to_s.gsub(/[^0-9A-Za-z_-]+/, '-').squeeze('-').gsub(/\A[-_]+|[-_]+\z/, '')
    normalized.presence || 'number'
  end

  def generated_refs_for(payload, existing_config)
    existing_refs = existing_config_refs(existing_config)
    if existing_refs[:number_ref].present? && same_existing_number?(payload,
                                                                    existing_config) && !legacy_internal_asterisk_provider_ref?(payload,
                                                                                                                                existing_refs)
      return existing_refs.merge(
        profile_refs: generated_refs(payload)[:profile_refs],
        profile_secret_refs: generated_refs(payload)[:profile_secret_refs]
      ).compact
    end

    return generated_refs(payload) if payload[:provider_kind].present? && payload[:ingress_number].present?

    existing_refs
  end

  def legacy_internal_asterisk_provider_ref?(payload, refs)
    payload[:provider_kind].to_s.in?(PROVIDER_OWNED_ROUTING_KINDS) && refs[:number_ref].to_s.include?('internal-asterisk')
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
      trunk_ref: resources[:trunk_ref],
      credentials_ref: provider_connection[:credentials_ref],
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

  def dry_run_status(errors)
    errors.empty? ? 'dry_run_ready' : 'validation_failed'
  end

  def dry_run_warnings(existing_config, _normalized_payload = nil)
    [].tap do |warnings|
      if existing_config&.dig(
        :ownership, :read_only
      )
        warnings << warning('legacy_resource_read_only',
                            'Existing legacy resource is read-only until managed migration is approved')
      end
    end
  end

  def mutation_warnings(_remote_result, _provider_kind = nil)
    []
  end

  def remote_commit_requested?(remote_commit)
    ActiveModel::Type::Boolean.new.cast(remote_commit)
  end

  def remote_commit_for(_provider_kind, _remote_commit)
    false
  end

  def local_native_provider_kind?(provider_kind)
    provider_kind.to_s.in?(LOCAL_NATIVE_PROVIDER_KINDS)
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
end
