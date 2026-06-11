# frozen_string_literal: true

class Telephony::VirtualPbx::ProvisioningService
  ALLOWED_PROVIDER_KINDS = %w[asterisk_analog sipuni].freeze
  DEFAULT_ROUTE_MODE = 'operator'
  DEFAULT_FALLBACK_MODE = 'reject'
  MANAGED_BY_ONELINK = 'onelink'
  LOCAL_OWNERSHIP_STATUS = 'local'
  REMOTE_MUTATION_REASON = 'REMOTE_MUTATION_REQUIRES_APPROVAL'

  def initialize(account:, current_user:, bridge_client: nil)
    @account = account
    @current_user = current_user
    @bridge_client = bridge_client
    @config_builder = Telephony::VirtualPbx::ConfigBuilder.new(account: account)
  end

  def show(inbox_id:)
    {
      operation: 'show',
      remote_commit: false,
      mutation_allowed: false,
      config: config_builder.for_inbox(inbox_id)
    }
  end

  def readiness_check(inbox_id:)
    config = config_builder.for_inbox(inbox_id)

    {
      operation: 'readiness_check',
      remote_commit: false,
      mutation_allowed: false,
      ready: config[:ready],
      config: config,
      warnings: config[:warnings]
    }
  end

  def templates
    {
      operation: 'templates',
      remote_commit: false,
      mutation_allowed: false,
      provider_templates: Telephony::VirtualPbx::ConfigBuilder.provider_templates
    }
  end

  def status(inbox_id:)
    config = config_builder.for_inbox(inbox_id)

    {
      operation: 'status',
      remote_commit: false,
      mutation_allowed: false,
      ready: config[:ready],
      status: config[:ready] ? 'ready' : 'action_required',
      config: config,
      warnings: config[:warnings]
    }
  end

  def create_channel(payload, dry_run: true, remote_commit: false)
    ensure_remote_mutation_not_requested!(remote_commit)
    normalized = normalize_payload(payload)
    errors = validation_errors(normalized, require_profiles: normalized[:profiles_supplied])

    if dry_run || errors.any?
      return dry_run_payload(operation: 'create', normalized_payload: normalized, errors: errors, existing_config: nil,
                             steps: create_steps(normalized))
    end

    mutation_payload('create', create_local_channel!(normalized), normalized, create_steps(normalized))
  end

  def update_channel(inbox_id:, payload:, dry_run: true, remote_commit: false)
    ensure_remote_mutation_not_requested!(remote_commit)
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
                             steps: update_steps(normalized, existing_config))
    end

    mutation_payload('update', update_local_channel!(inbox_id, normalized), normalized, update_steps(normalized, existing_config))
  end

  def delete_channel(inbox_id:, confirm: false, dry_run: true, remote_commit: false)
    ensure_remote_mutation_not_requested!(remote_commit)
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
                             existing_config: existing_config, steps: delete_steps(existing_config))
    end

    mutation_payload(
      'delete',
      delete_local_channel!(inbox_id),
      { inbox_id: inbox_id, confirm: confirm },
      delete_steps(existing_config),
      existing_config: existing_config
    )
  end

  private

  attr_reader :account, :current_user, :bridge_client, :config_builder

  def dry_run_payload(operation:, normalized_payload:, errors:, existing_config:, steps:)
    sanitized_payload = Telephony::VirtualPbx::ConfigBuilder.sanitize(normalized_payload)

    {
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
      payload: sanitized_payload,
      provider_template: provider_template_for(normalized_payload, existing_config),
      generated_refs: generated_refs_for(normalized_payload, existing_config),
      bridge_operations: bridge_operations_for(operation, normalized_payload, existing_config: existing_config),
      existing_config: existing_config,
      steps: steps,
      errors: errors,
      warnings: dry_run_warnings(existing_config)
    }.compact
  end

  def mutation_payload(operation, mutation_result, normalized_payload, steps, existing_config: nil)
    {
      operation: operation,
      dry_run: false,
      valid: true,
      status: 'local_committed',
      local_commit: true,
      remote_commit: false,
      mutation_allowed: true,
      remote_mutation_allowed: false,
      remote_mutation_reason: REMOTE_MUTATION_REASON,
      mutation_reason: 'local_commit_remote_mutation_disabled',
      account_id: account.id,
      requested_by_id: current_user&.id,
      payload: Telephony::VirtualPbx::ConfigBuilder.sanitize(normalized_payload),
      provider_template: provider_template_for(normalized_payload, existing_config),
      generated_refs: generated_refs_for(normalized_payload, existing_config),
      bridge_operations: bridge_operations_for(operation, normalized_payload, existing_config: existing_config),
      config: mutation_result[:inbox_id].present? ? config_builder.for_inbox(mutation_result[:inbox_id]) : nil,
      deleted: mutation_result[:deleted],
      deleted_inbox_id: mutation_result[:deleted_inbox_id],
      steps: steps,
      errors: [],
      warnings: [warning('remote_mutation_disabled', 'Fonoster/Routr/bridge writes were not executed')]
    }.compact
  end

  def normalize_payload(payload, fallback: nil)
    source = payload.to_h.deep_stringify_keys
    fallback_phone_numbers = fallback&.fetch(:phone_numbers, {}) || {}
    fallback_routing = fallback&.fetch(:routing, {}) || {}

    provider_kind = normalize_provider_kind(source['provider_kind'].presence || fallback&.dig(:provider_kind))
    ingress_number = first_present(
      source['ingress_number'],
      source['sipuni_ingress_number'],
      source['provider_number'],
      fallback_phone_numbers[:ingress_number]
    )
    provider_account_number = first_present(
      source['provider_account_number'],
      source['sipuni_account_number'],
      source['account_number'],
      fallback_phone_numbers[:provider_account_number],
      ingress_number
    )
    profiles_supplied = source.key?('profiles')

    {
      provider_kind: provider_kind,
      channel_name: first_present(source['channel_name'], source['name'], fallback&.dig(:name)),
      display_phone_number: first_present(source['display_phone_number'], source['phone_number'], fallback_phone_numbers[:display_phone_number]),
      provider_account_number: provider_account_number,
      ingress_number: ingress_number,
      fonoster_tel_url: first_present(source['fonoster_tel_url'], source['tel_url'], fallback_phone_numbers[:fonoster_tel_url],
                                      tel_url_for(ingress_number)),
      connection: normalize_connection(source['connection'] || {}, provider_kind, fallback&.dig(:resources, :provider_connection)),
      profiles: profiles_supplied ? normalize_profiles(source['profiles']) : normalize_existing_profiles(fallback&.dig(:profiles)),
      profiles_supplied: profiles_supplied,
      routing: normalize_routing(source['routing'] || {}, fallback_routing),
      metadata: normalize_metadata(source['metadata'] || {})
    }.compact
  end

  def normalize_connection(source, provider_kind, fallback)
    source = source.to_h.deep_stringify_keys
    fallback = (fallback || {}).with_indifferent_access
    template = Telephony::VirtualPbx::ConfigBuilder::PROVIDER_TEMPLATES.fetch(provider_kind, {})
    port_source = source.key?('port') ? source['port'] : first_present(fallback[:port], template[:default_port], 5060)

    {
      host: first_present(source['host'], fallback[:host]),
      port: normalize_port(port_source),
      transport: first_present(source['transport'], fallback[:transport], template[:default_transport], 'udp'),
      username: first_present(source['username'], fallback[:username]),
      password: source['password'].presence,
      send_register: source.key?('send_register') ? ActiveModel::Type::Boolean.new.cast(source['send_register']) : fallback[:send_register]
    }.compact
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
      {
        user_id: attrs['user_id'].presence&.to_i,
        internal_extension: attrs['internal_extension'].presence,
        sip_username: attrs['sip_username'].presence,
        sip_password: attrs['sip_password'].presence,
        sip_password_configured: ActiveModel::Type::Boolean.new.cast(attrs['sip_password_configured']),
        enabled: attrs.key?('enabled') ? ActiveModel::Type::Boolean.new.cast(attrs['enabled']) : true
      }.compact
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
        enabled: attrs.key?(:enabled) ? attrs[:enabled] : true
      }.compact
    end
  end

  def normalize_routing(source, fallback)
    source = source.to_h.deep_stringify_keys
    {
      mode: source['mode'].presence || fallback[:mode] || DEFAULT_ROUTE_MODE,
      fallback_mode: source['fallback_mode'].presence || fallback[:fallback_mode] || DEFAULT_FALLBACK_MODE,
      ai_enabled: source.key?('ai_enabled') ? ActiveModel::Type::Boolean.new.cast(source['ai_enabled']) : ActiveModel::Type::Boolean.new.cast(fallback[:ai_enabled]),
      operator_agent_aor: source['operator_agent_aor'].presence || fallback[:operator_agent_aor]
    }.compact
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

    account.telephony_sip_profiles
           .where(inbox_id: inbox_id, user_id: profile[:user_id], internal_extension: profile[:internal_extension])
           .where.not(password_secret_ref: [nil, ''])
           .exists?
  end

  def password_secret_ref_for(profile_record, profile, payload, index)
    return nil if profile[:sip_username].blank?
    return generated_refs(payload)[:profile_secret_refs][index] if profile[:sip_password].present?

    profile_record.password_secret_ref
  end

  def create_local_channel!(payload)
    result = nil
    ActiveRecord::Base.transaction do
      provider_connection = upsert_provider_connection!(payload)
      channel = Channel::Voice.create!(account: account, phone_number: payload[:display_phone_number], provider: 'fonoster',
                                       provider_config: provider_config_for(payload, provider_connection))
      inbox = Inbox.create!(account: account, channel: channel, name: payload[:channel_name])
      binding = upsert_number_binding!(inbox, channel, payload, provider_connection)
      upsert_routing_policy!(binding, payload)
      result = { inbox_id: inbox.id }
    end
    result
  end

  def update_local_channel!(inbox_id, payload)
    result = nil
    ActiveRecord::Base.transaction do
      inbox = account.inboxes.find(inbox_id)
      channel = inbox.channel
      binding = inbox.telephony_number_binding
      provider_connection = upsert_provider_connection!(payload, existing: binding&.provider_connection)

      inbox.update!(name: payload[:channel_name])
      channel.update!(phone_number: payload[:display_phone_number],
                      provider_config: provider_config_for(payload, provider_connection, channel.provider_config_hash))
      binding = upsert_number_binding!(inbox, channel, payload, provider_connection)
      upsert_routing_policy!(binding, payload)
      upsert_sip_profiles!(inbox, provider_connection, payload) if payload[:profiles_supplied]
      result = { inbox_id: inbox.id }
    end
    result
  end

  def delete_local_channel!(inbox_id)
    result = nil
    ActiveRecord::Base.transaction do
      inbox = account.inboxes.find(inbox_id)
      provider_connection = inbox.telephony_number_binding&.provider_connection
      deleted_inbox_id = inbox.id

      inbox.telephony_sip_profiles.destroy_all
      inbox.destroy!
      destroy_provider_connection_if_orphaned!(provider_connection)
      result = { deleted: true, deleted_inbox_id: deleted_inbox_id }
    end
    result
  end

  def upsert_provider_connection!(payload, existing: nil)
    connection = existing || account.telephony_provider_connections.find_or_initialize_by(
      provider_kind: payload[:provider_kind],
      name: provider_connection_name(payload)
    )
    connection.assign_attributes(
      provider_kind: payload[:provider_kind],
      name: provider_connection_name(payload),
      host: payload.dig(:connection, :host),
      port: payload.dig(:connection, :port),
      transport: payload.dig(:connection, :transport),
      username: payload.dig(:connection, :username),
      password_secret_ref: payload.dig(:connection, :password).present? ? generated_refs(payload)[:credentials_ref] : connection.password_secret_ref,
      credentials_ref: generated_refs(payload)[:credentials_ref],
      fonoster_trunk_ref: generated_refs(payload)[:trunk_ref],
      send_register: ActiveModel::Type::Boolean.new.cast(payload.dig(:connection, :send_register)) || false,
      status: 'draft',
      managed_by: MANAGED_BY_ONELINK,
      ownership_status: LOCAL_OWNERSHIP_STATUS,
      metadata: payload[:metadata],
      updated_by: current_user
    )
    connection.created_by ||= current_user if connection.new_record?
    connection.save!
    connection
  end

  def upsert_number_binding!(inbox, channel, payload, provider_connection)
    binding = inbox.telephony_number_binding || inbox.build_telephony_number_binding(account: account)
    binding.assign_attributes(
      account: account,
      provider: 'fonoster',
      number_ref: generated_refs(payload)[:number_ref],
      phone_number: payload[:ingress_number],
      display_phone_number: payload[:display_phone_number],
      provider_account_number: payload[:provider_account_number],
      ingress_number: payload[:ingress_number],
      fonoster_tel_url: payload[:fonoster_tel_url],
      app_ref: channel.provider_config_hash.with_indifferent_access[:app_ref],
      trunk_ref: generated_refs(payload)[:trunk_ref],
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
      settings: (policy.settings || {}).merge('virtual_pbx_local' => true)
    )
    policy.save!
    policy
  end

  def upsert_sip_profiles!(inbox, provider_connection, payload)
    desired_keys = []
    Array.wrap(payload[:profiles]).each_with_index do |profile, index|
      profile_record = account.telephony_sip_profiles.find_or_initialize_by(
        inbox: inbox,
        user_id: profile[:user_id],
        internal_extension: profile[:internal_extension]
      )
      profile_record.assign_attributes(
        provider_connection: provider_connection,
        sip_username: profile[:sip_username],
        password_secret_ref: password_secret_ref_for(profile_record, profile, payload, index),
        sip_host: payload.dig(:connection, :host),
        agent_ref: generated_refs(payload)[:profile_refs][index],
        agent_aor: generated_profile_aor(profile, payload),
        fonoster_agent_ref: generated_refs(payload)[:profile_refs][index],
        credentials_ref: profile[:sip_username].present? ? generated_refs(payload)[:profile_secret_refs][index] : nil,
        enabled: profile.fetch(:enabled, true),
        availability_mode: 'external_extension',
        status: 'draft',
        managed_by: MANAGED_BY_ONELINK,
        ownership_status: LOCAL_OWNERSHIP_STATUS,
        metadata: { provider_kind: payload[:provider_kind] }
      )
      profile_record.save!
      desired_keys << profile_record.id
    end
    inbox.telephony_sip_profiles.where.not(id: desired_keys).destroy_all
  end

  def provider_config_for(payload, provider_connection, base = {})
    base.with_indifferent_access.merge(
      provider_kind: payload[:provider_kind],
      number_ref: generated_refs(payload)[:number_ref],
      trunk_ref: generated_refs(payload)[:trunk_ref],
      display_phone_number: payload[:display_phone_number],
      provider_account_number: payload[:provider_account_number],
      ingress_number: payload[:ingress_number],
      fonoster_tel_url: payload[:fonoster_tel_url],
      routing_mode: payload.dig(:routing, :mode),
      fallback_mode: payload.dig(:routing, :fallback_mode),
      operator_agent_aor: operator_agent_aor_for(payload),
      provider_connection_id: provider_connection.id,
      managed_by: MANAGED_BY_ONELINK,
      ownership_status: LOCAL_OWNERSHIP_STATUS,
      source: payload.dig(:metadata, 'source') || payload[:provider_kind]
    ).compact
  end

  def provider_connection_name(payload)
    first_present(payload.dig(:metadata, 'source'), payload[:channel_name], payload[:provider_kind])
  end

  def operator_agent_aor_for(payload)
    payload.dig(:routing, :operator_agent_aor).presence || generated_profile_aor(Array.wrap(payload[:profiles]).first || {}, payload)
  end

  def generated_profile_aor(profile, payload)
    extension = profile[:internal_extension].presence || 'operator'
    host = payload.dig(:connection, :host).presence || 'voice.local'
    "sip:#{extension}@#{host}"
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

  def create_steps(payload)
    refs = generated_refs(payload)
    [
      step('validate_payload', 'Validate channel, provider connection, and optional employee SIP profiles'),
      step('upsert_provider_connection', 'Upsert local provider connection/trunk ownership metadata', local_model: 'Telephony::ProviderConnection'),
      step('create_channel_voice', 'Create Channel::Voice with display_phone_number and sanitized provider_config', local_model: 'Channel::Voice'),
      step('create_inbox', 'Create inbox; collaborators are managed by the normal inbox members flow', local_model: 'Inbox'),
      step('create_number_binding', 'Create telephony number binding with ingress_number and deterministic number_ref',
           local_model: 'Telephony::NumberBinding', ref: refs[:number_ref]),
      step('create_routing_policy', 'Create routing policy as runtime source of truth', local_model: 'Telephony::RoutingPolicy'),
      step('defer_sip_profiles', 'Assign inbox collaborators and employee SIP profiles later in settings'),
      step('skip_remote_bridge_mutation', 'Remote Fonoster/Routr/bridge writes are blocked', remote: true)
    ]
  end

  def update_steps(payload, existing_config)
    refs = generated_refs(payload)
    [
      step('load_existing_config', 'Loaded current virtual PBX bundle', inbox_id: existing_config[:inbox_id]),
      step('validate_update_payload', 'Validate editable channel, connection, profile, and routing fields'),
      step('update_local_bundle', 'Update managed local records only after ownership checks', ref: refs[:number_ref]),
      step('skip_remote_bridge_mutation', 'Remote Fonoster/Routr/bridge writes are blocked', remote: true)
    ]
  end

  def delete_steps(existing_config)
    [
      step('load_existing_config', 'Loaded current virtual PBX bundle', inbox_id: existing_config[:inbox_id]),
      step('check_active_calls', 'Block deletion when active calls exist'),
      step('check_ownership', 'Delete only uniquely-owned managed resources'),
      step('skip_remote_bridge_mutation', 'Remote Fonoster/Routr/bridge deletes are blocked', remote: true)
    ]
  end

  def generated_refs(payload)
    provider_kind = payload[:provider_kind]
    ingress_number = payload[:ingress_number]
    safe_ingress = ingress_number.to_s.gsub(/[^0-9A-Za-z_-]/, '-')
    number_ref = if provider_kind == 'sipuni'
                   "sipuni-internal-asterisk-#{payload[:provider_account_number].presence || safe_ingress}"
                 else
                   "asterisk-analog-#{account.id}-#{safe_ingress}"
                 end

    profiles = Array.wrap(payload[:profiles])
    {
      number_ref: number_ref,
      trunk_ref: "trunk-#{provider_kind}-acct-#{account.id}-#{safe_ingress}",
      credentials_ref: "cred-#{provider_kind}-acct-#{account.id}-#{safe_ingress}",
      profile_refs: profiles.map { |profile| "profile-#{account.id}-#{profile[:user_id]}-#{profile[:internal_extension]}" },
      profile_secret_refs: profiles.map { |profile| "cred-profile-#{account.id}-#{profile[:user_id]}-#{profile[:internal_extension]}" }
    }
  end

  def generated_refs_for(payload, existing_config)
    return generated_refs(payload) if payload[:provider_kind].present? && payload[:ingress_number].present?

    existing_config_refs(existing_config)
  end

  def existing_config_refs(existing_config)
    config = (existing_config || {}).with_indifferent_access
    resources = (config[:resources] || {}).with_indifferent_access
    provider_connection = (resources[:provider_connection] || {}).with_indifferent_access

    {
      number_ref: resources[:number_ref],
      trunk_ref: resources[:trunk_ref] || provider_connection[:fonoster_trunk_ref],
      credentials_ref: provider_connection[:credentials_ref] || provider_connection[:fonoster_credentials_ref],
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
                                bridge_operation('upsert_credentials', 'PUT', bridge_path('/telephony/credentials/', refs[:credentials_ref]),
                                                 'Upsert provider credentials'),
                                bridge_operation('upsert_trunk', 'PUT', bridge_path('/telephony/trunks/', refs[:trunk_ref]),
                                                 'Upsert provider trunk'),
                                bridge_operation('upsert_number', 'PUT', bridge_path('/telephony/numbers/', refs[:number_ref]),
                                                 'Upsert inbound number'),
                                bridge_operation('update_number_route', 'PATCH', bridge_path('/telephony/numbers/', refs[:number_ref], '/route'),
                                                 'Point number route to OneLink runtime bridge'),
                                *profile_bridge_operations(payload, refs, 'PUT')
                              ])
  end

  def update_bridge_operations(payload)
    refs = generated_refs(payload)
    compact_bridge_operations([
                                bridge_operation('patch_trunk', 'PATCH', bridge_path('/telephony/trunks/', refs[:trunk_ref]),
                                                 'Patch provider trunk metadata'),
                                bridge_operation('patch_number', 'PATCH', bridge_path('/telephony/numbers/', refs[:number_ref]),
                                                 'Patch inbound number metadata'),
                                bridge_operation('patch_number_route', 'PATCH', bridge_path('/telephony/numbers/', refs[:number_ref], '/route'),
                                                 'Patch number route headers'),
                                *profile_bridge_operations(payload, refs, 'PUT')
                              ])
  end

  def delete_bridge_operations(existing_config)
    refs = existing_config_refs(existing_config)
    compact_bridge_operations([
                                bridge_operation('delete_number', 'DELETE', bridge_path('/telephony/numbers/', refs[:number_ref]),
                                                 'Delete owned inbound number'),
                                bridge_operation('delete_trunk', 'DELETE', bridge_path('/telephony/trunks/', refs[:trunk_ref]),
                                                 'Delete channel-owned trunk when it is not shared'),
                                bridge_operation('delete_credentials', 'DELETE', bridge_path('/telephony/credentials/', refs[:credentials_ref]),
                                                 'Delete channel-owned credentials when they are not shared')
                              ])
  end

  def profile_bridge_operations(payload, refs, method)
    Array.wrap(payload[:profiles]).each_with_index.map do |_profile, index|
      bridge_operation('upsert_agent', method, bridge_path('/telephony/agents/', refs[:profile_refs][index]),
                       'Upsert employee SIP agent profile')
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

  def dry_run_status(errors)
    errors.empty? ? 'dry_run_ready' : 'validation_failed'
  end

  def dry_run_warnings(existing_config)
    [].tap do |warnings|
      warnings << warning('remote_mutation_disabled', 'Fonoster/Routr/bridge writes are not executed in this safe slice')
      if existing_config&.dig(
        :ownership, :read_only
      )
        warnings << warning('legacy_resource_read_only',
                            'Existing legacy resource is read-only until managed migration is approved')
      end
    end
  end

  def ensure_remote_mutation_not_requested!(remote_commit)
    return unless ActiveModel::Type::Boolean.new.cast(remote_commit)

    raise Telephony::Error.new(
      code: 'REMOTE_MUTATION_REQUIRES_APPROVAL',
      message: 'Remote Fonoster/Routr mutation requires separate explicit approval',
      status: :unprocessable_content
    )
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

  def tel_url_for(value)
    value.present? ? "tel:#{value}" : nil
  end
end
