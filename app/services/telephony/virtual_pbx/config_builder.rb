# frozen_string_literal: true

require 'digest'

class Telephony::VirtualPbx::ConfigBuilder
  MANAGED_BY_ONELINK = 'onelink'
  SECRET_KEY_PATTERN = /(password|secret|token|api[_-]?key|credential|auth)/i
  PROVIDER_OWNED_SIP_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze
  UNKNOWN_PROVIDER_TEMPLATE = {
    label: 'SIP provider',
    default_transport: 'udp',
    default_port: 5060,
    allows_display_ingress_split: true,
    default_route_mode: 'operator',
    default_operator_distribution_mode: Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_BROADCAST
  }.freeze

  PROVIDER_TEMPLATES = {
    'asterisk_analog' => {
      label: 'Asterisk analog',
      default_transport: 'udp',
      default_port: 5060,
      allows_display_ingress_split: true,
      default_route_mode: 'operator',
      default_operator_distribution_mode: Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_BROADCAST
    },
    'sipuni' => {
      label: 'Sipuni',
      default_transport: 'udp',
      default_port: 5060,
      allows_display_ingress_split: true,
      default_route_mode: 'operator',
      default_operator_distribution_mode: Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_BROADCAST
    },
    'binotel' => {
      label: 'Binotel',
      default_transport: 'udp',
      default_port: 5060,
      allows_display_ingress_split: true,
      default_route_mode: 'operator',
      default_operator_distribution_mode: Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_BROADCAST
    }
  }.freeze

  def initialize(account:)
    @account = account
  end

  def for_inbox(inbox_or_id)
    inbox = resolve_inbox(inbox_or_id)
    channel = inbox.channel
    unless channel.is_a?(Channel::Voice)
      raise Telephony::Error.new(code: 'NOT_VOICE_CHANNEL', message: 'Inbox is not a voice channel',
                                 status: :unprocessable_content)
    end
    unless channel.provider.in?(PROVIDER_OWNED_SIP_PROVIDERS)
      raise Telephony::Error.new(code: 'UNSUPPORTED_PROVIDER', message: 'Only native voice channels can be reconciled as Virtual PBX channels',
                                 status: :unprocessable_content)
    end

    build_config(inbox, channel)
  end

  def split_configured?(channel:, binding:)
    return false if channel.blank? || binding.blank?

    parts = phone_parts(channel: channel, binding: binding)
    template_for(parts[:provider_kind])[:allows_display_ingress_split] &&
      parts[:display_phone_number].present? &&
      parts[:ingress_number].present? &&
      parts[:display_phone_number] != parts[:ingress_number]
  rescue JSON::ParserError, TypeError
    false
  end

  def self.sanitize(value)
    new(account: nil).sanitize(value)
  end

  def self.provider_templates
    PROVIDER_TEMPLATES.deep_dup
  end

  def self.to_ui_config(config)
    new(account: nil).ui_config_from(config)
  end

  def ui_config_for(inbox_or_id)
    ui_config_from(for_inbox(inbox_or_id))
  end

  def ui_config_from(config)
    config = (config || {}).with_indifferent_access
    phone_numbers = (config[:phone_numbers] || {}).with_indifferent_access
    resources = (config[:resources] || {}).with_indifferent_access
    provider_connection = (resources[:provider_connection] || {}).with_indifferent_access
    provider_connection_metadata = (provider_connection[:metadata] || {}).with_indifferent_access
    routing = (config[:routing] || {}).with_indifferent_access
    ownership = (config[:ownership] || {}).with_indifferent_access
    provider_template = template_for(config[:provider_kind])

    {
      id: config[:id],
      inbox_id: config[:inbox_id],
      configuration_version: config[:configuration_version],
      status: ui_status_payload(config, ownership, resources),
      channel: {
        name: config[:name],
        provider_kind: config[:provider_kind],
        provider_label: provider_template[:label],
        display_phone_number: phone_numbers[:display_phone_number]
      }.compact,
      connection: {
        provider_kind: config[:provider_kind],
        provider_label: provider_template[:label],
        display_name: provider_connection[:name] || provider_template[:label],
        provider_number: first_present(phone_numbers[:provider_account_number], phone_numbers[:display_phone_number]),
        host: provider_connection[:host],
        port: provider_connection[:port],
        transport: provider_connection[:transport],
        outbound_dial_format: provider_connection_metadata[:outbound_dial_format],
        outboundDialFormat: provider_connection_metadata[:outbound_dial_format],
        send_register: provider_connection[:send_register],
        configured: provider_connection.present? || phone_numbers[:ingress_number].present?,
        status: provider_connection[:status] || (config[:ready] ? 'ready' : 'action_required'),
        remote_mutations: remote_mutation_status,
        last_synced_at: first_present(resources[:last_synced_at], provider_connection[:last_synced_at])
      }.compact,
      routing: {
        mode: routing[:mode],
        fallback_mode: routing[:fallback_mode],
        ai_enabled: routing[:ai_enabled],
        operator_distribution_mode: routing[:operator_distribution_mode],
        max_call_duration_seconds: routing[:max_call_duration_seconds],
        show_calls_handled_by_other_operators: routing[:show_calls_handled_by_other_operators],
        operator_target_configured: routing[:operator_agent_aor].present? || routing[:operator_agent_ref].present?
      }.compact,
      employees: ui_employees_payload(config[:profiles]),
      permissions: {
        editable: !ownership[:read_only],
        remote_commit_allowed: false,
        diagnostics_available: true
      },
      warnings: config[:warnings] || []
    }.compact
  end

  def sanitize(value, parent_key = nil)
    case value
    when Hash
      value.each_with_object({}) do |(key, child), sanitized|
        sanitized[key.to_s] = secret_key?(key) ? redacted_value(child) : sanitize(child, key)
      end
    when Array
      value.map { |child| sanitize(child, parent_key) }
    else
      secret_key?(parent_key) ? redacted_value(value) : value
    end
  end

  private

  attr_reader :account

  def resolve_inbox(inbox_or_id)
    return inbox_or_id if inbox_or_id.is_a?(Inbox) && inbox_or_id.account_id == account.id

    account.inboxes.find(inbox_or_id)
  end

  def ui_status_payload(config, ownership, resources)
    status = first_present(resources[:provisioning_status], config[:provisioning_status])
    status ||= if ownership[:read_only]
                 'requires_manual_reconcile'
               else
                 (config[:ready] ? 'local_only' : 'action_required')
               end

    {
      ready: config[:ready],
      status: status,
      label: ui_status_label(status),
      read_only: ownership[:read_only],
      remote_mutations: remote_mutation_status,
      last_synced_at: resources[:last_synced_at]
    }.compact
  end

  def remote_mutation_status
    'disabled'
  end

  def ui_status_label(status)
    case status
    when 'local_only'
      'Локальная конфигурация Janus SIP'
    when 'dry_run_valid'
      'Готов к синхронизации'
    when 'remote_failed'
      'Ошибка синхронизации'
    when 'requires_manual_reconcile', 'action_required'
      'Нужно действие'
    else
      'Локально'
    end
  end

  def ui_employees_payload(profiles)
    Array.wrap(profiles).map do |profile|
      attrs = profile.with_indifferent_access
      {
        id: attrs[:id],
        profile_kind: attrs[:profile_kind],
        voice_agent: ActiveModel::Type::Boolean.new.cast(attrs[:voice_agent]) ||
          attrs[:profile_kind].to_s == Telephony::SipProfile::PROFILE_KIND_VOICE_AGENT,
        user_id: attrs[:user_id],
        user_name: attrs[:user_name],
        internal_extension: attrs[:internal_extension],
        sip_username: attrs[:sip_username],
        sip_password_configured: attrs[:sip_password_configured],
        access_configured: attrs[:sip_password_configured] || attrs[:credentials_ref].present?,
        enabled: attrs[:enabled]
      }.compact
    end
  end

  def build_config(inbox, channel)
    binding = inbox.telephony_number_binding
    policy = binding&.routing_policy
    parts = phone_parts(channel: channel, binding: binding)
    provider_kind = parts[:provider_kind]
    warnings = readiness_warnings(channel: channel, binding: binding, policy: policy, parts: parts)

    {
      id: inbox.id,
      inbox_id: inbox.id,
      channel_id: channel.id,
      account_id: account.id,
      configuration_version: configuration_version_for(inbox, channel, binding, policy),
      provider: channel.provider,
      provider_kind: provider_kind,
      provider_template: template_for(provider_kind),
      name: inbox.name,
      phone_numbers: parts.except(:provider_kind),
      resources: resources_payload(channel: channel, binding: binding, policy: policy),
      routing: routing_payload(channel: channel, binding: binding, policy: policy),
      profiles: profiles_payload(inbox: inbox),
      ownership: ownership_payload(channel: channel, binding: binding),
      provider_config: sanitize(provider_config_hash(channel)),
      metadata: sanitize(binding&.metadata || {}),
      ready: blocking_warnings(warnings).empty?,
      warnings: warnings
    }.compact
  end

  SIP_PROFILE_RUNTIME_METADATA_KEYS = %w[
    available
    browser_registration_lease
    last_presence_event_at
    last_presence_sequence
    last_presence_source
    last_registration_instance_id
    last_unregistered_event_at
    presence
    registered
    registration_config_version
    registration_context
    registration_context_signature
    registration_state
  ].freeze

  def configuration_version_for(inbox, channel, binding, policy)
    records = [
      inbox,
      channel,
      binding,
      policy,
      binding&.provider_connection,
      *inbox.telephony_sip_profiles.order(:id).to_a
    ].compact

    payload = records.map { |record| configuration_fingerprint_for(record) }
    Digest::SHA256.hexdigest(JSON.generate(canonical_configuration_value(payload)))
  end

  def configuration_fingerprint_for(record)
    attributes = record.attributes.except('created_at', 'updated_at', 'last_synced_at')
    attributes['metadata'] = record.metadata.to_h.except(*SIP_PROFILE_RUNTIME_METADATA_KEYS) if record.is_a?(Telephony::SipProfile)
    [record.class.base_class.name, attributes]
  end

  def canonical_configuration_value(value)
    case value
    when Hash
      value.keys.sort.index_with { |key| canonical_configuration_value(value[key]) }
    when Array
      value.map { |entry| canonical_configuration_value(entry) }
    else
      value
    end
  end

  def phone_parts(channel:, binding:)
    provider_config = provider_config_hash(channel)
    metadata = metadata_hash(binding)
    provider_kind = normalize_provider_kind(
      first_present(
        provider_config[:provider_kind],
        metadata[:provider_kind],
        metadata[:source],
        channel.provider,
        infer_provider_kind(provider_config: provider_config, binding: binding)
      )
    )
    display_phone_number = first_present(
      binding&.display_phone_number,
      provider_config[:display_phone_number],
      metadata[:display_phone_number],
      channel.phone_number
    )
    provider_account_number = normalize_technical_number(
      first_present(
        binding&.provider_account_number,
        provider_config[:provider_account_number],
        metadata[:provider_account_number],
        provider_config[:sipuni_account_number],
        metadata[:sipuni_account_number],
        provider_config[:binotel_account_number],
        metadata[:binotel_account_number],
        provider_config[:account_number],
        metadata[:account_number]
      )
    )
    ingress_tel_url = normalize_tel_url(
      first_present(
        binding&.fonoster_tel_url,
        provider_config[:fonoster_tel_url],
        metadata[:fonoster_tel_url],
        metadata[:tel_url],
        provider_config[:tel_url]
      )
    )
    ingress_number = normalize_technical_number(
      first_present(
        provider_config[:ingress_number],
        metadata[:ingress_number],
        provider_config[:sipuni_ingress_number],
        metadata[:sipuni_ingress_number],
        provider_config[:binotel_ingress_number],
        metadata[:binotel_ingress_number],
        tel_url_number(ingress_tel_url),
        binding&.ingress_number,
        binding&.phone_number,
        provider_account_number,
        display_phone_number
      )
    )

    phone_payload = {
      provider_kind: provider_kind,
      display_phone_number: display_phone_number,
      provider_account_number: provider_account_number,
      ingress_number: ingress_number,
      display_matches_ingress: display_phone_number.present? && ingress_number.present? && display_phone_number == ingress_number,
      binding_represents_ingress: binding&.phone_number.present? && ingress_number.present? && binding.phone_number == ingress_number,
      legacy_channel_phone_differs_from_binding: channel.phone_number.present? && binding&.phone_number.present? &&
                                                 channel.phone_number != binding.phone_number,
      split_allowed: template_for(provider_kind)[:allows_display_ingress_split]
    }
    phone_payload.compact
  end

  def resources_payload(channel:, binding:, policy:)
    provider_owned_sip = provider_owned_sip_channel?(channel)
    {
      inbox_id: channel.inbox&.id,
      channel_id: channel.id,
      number_binding_id: binding&.id,
      routing_policy_id: policy&.id,
      number_ref: binding&.number_ref,
      app_ref: provider_owned_sip ? nil : binding&.configured_app_ref,
      runtime_app_ref: provider_owned_sip ? nil : binding&.runtime_app_ref,
      trunk_ref: provider_owned_sip ? nil : binding&.trunk_ref,
      provider_connection: binding&.provider_connection&.to_virtual_pbx_h,
      last_synced_at: binding&.last_synced_at,
      provisioning_status: telephony_attribute(binding, :provisioning_status),
      last_reconciled_at: telephony_attribute(binding, :last_reconciled_at),
      remote_drift_detected_at: telephony_attribute(binding, :remote_drift_detected_at),
      remote_drift_summary: telephony_attribute(binding, :remote_drift_summary)
    }.compact
  end

  def routing_payload(channel:, binding:, policy:)
    return { show_calls_handled_by_other_operators: channel.show_calls_handled_by_other_operators? } if binding.blank? && policy.blank?

    provider_owned_sip = provider_owned_sip_provider?(binding&.provider)
    {
      mode: policy&.mode,
      bridge_mode: policy&.bridge_mode,
      effective_app_ref: provider_owned_sip ? nil : binding&.app_ref_for_policy(policy),
      operator_agent_ref: policy&.operator_agent_ref,
      operator_agent_aor: policy&.resolved_operator_agent_aor,
      operator_distribution_mode: policy&.operator_distribution_mode,
      max_call_duration_seconds: policy&.max_call_duration_seconds || Telephony::RoutingPolicy::DEFAULT_MAX_CALL_DURATION_SECONDS,
      show_calls_handled_by_other_operators: channel.show_calls_handled_by_other_operators?,
      fallback_mode: policy&.fallback_mode,
      ai_enabled: policy&.ai_enabled,
      ai_app_ref: policy&.effective_ai_app_ref
    }.compact
  end

  def profiles_payload(inbox:)
    account.telephony_sip_profiles
           .where(inbox: inbox)
           .recent
           .limit(20)
           .map { |profile| sanitize(profile.to_telephony_h) }
  end

  def ownership_payload(channel:, binding:)
    metadata = metadata_hash(binding).merge(provider_config_hash(channel))
    managed_by = first_present(binding&.managed_by, metadata[:managed_by], metadata[:managedBy])
    status = first_present(binding&.ownership_status, metadata[:ownership_status], metadata[:ownershipStatus])
    managed = binding&.managed? || managed_by == MANAGED_BY_ONELINK || status == 'managed'

    {
      managed: managed,
      managed_by: managed_by,
      ownership_status: status.presence || (managed ? 'managed' : 'legacy_reference'),
      read_only: !managed,
      provider_connection_id: first_present(binding&.provider_connection_id, metadata[:provider_connection_id], metadata[:providerConnectionId]),
      source: first_present(metadata[:source], metadata[:provider_kind])
    }.compact
  end

  def readiness_warnings(channel:, binding:, policy:, parts:)
    [].tap do |warnings|
      warnings << warning('missing_number_binding', 'Telephony number binding is missing', severity: 'blocking') if binding.blank?
      warnings << warning('missing_provider_kind', 'Telephony provider kind is missing', severity: 'blocking') if parts[:provider_kind].blank?
      warnings << warning('missing_routing_policy', 'Telephony routing policy is missing', severity: 'blocking') if binding.present? && policy.blank?
      if binding.present? && binding.number_ref.blank?
        warnings << warning('missing_number_ref', 'Telephony number ref is missing',
                            severity: 'blocking')
      end
      warnings << warning('missing_ingress_number', 'Technical ingress number is missing', severity: 'blocking') if parts[:ingress_number].blank?
      if parts[:display_phone_number].blank?
        warnings << warning('missing_display_phone_number', 'Display phone number is missing',
                            severity: 'blocking')
      end
      warnings << split_phone_warning(parts)
      warnings << provider_managed_gateway_credentials_warning(channel: channel, binding: binding, parts: parts)
      warnings << legacy_ownership_warning(channel: channel, binding: binding)
    end.compact
  end

  def provider_managed_gateway_credentials_warning(channel:, binding:, parts:)
    provider_kind = parts[:provider_kind].to_s
    return unless provider_kind.in?(%w[sipuni binotel])
    return unless ownership_payload(channel: channel, binding: binding)[:managed]

    connection = binding&.provider_connection
    return if connection.blank? || !connection.send_register?
    return if provider_sip_device_credentials_configured?(connection)

    warning(
      'missing_provider_sip_device_credentials',
      'OneLink SIP device credentials are missing; configure SIP login and password before SIP registration',
      severity: 'blocking'
    )
  end

  def provider_sip_device_credentials_configured?(connection)
    connection.username.present? && connection.password_secret_ref.present?
  end

  def provider_owned_sip_channel?(channel)
    provider_owned_sip_provider?(channel&.provider)
  end

  def provider_owned_sip_connection?(connection)
    connection&.provider_kind.to_s.in?(PROVIDER_OWNED_SIP_PROVIDERS)
  end

  def provider_owned_sip_provider?(provider)
    provider.to_s.in?(PROVIDER_OWNED_SIP_PROVIDERS)
  end

  def normalized_sip_identity(value)
    value.to_s.strip.presence
  end

  def split_phone_warning(parts)
    return unless parts[:legacy_channel_phone_differs_from_binding]

    if parts[:split_allowed]
      return warning('phone_split_configured', 'Display phone and technical ingress number are intentionally different',
                     severity: 'info')
    end

    warning('phone_number_mismatch', 'Telephony number binding phone does not match inbox phone', severity: 'blocking')
  end

  def legacy_ownership_warning(channel:, binding:)
    return if ownership_payload(channel: channel, binding: binding)[:managed]

    warning('legacy_reference_resource', 'Resource has no OneLink-managed ownership metadata and is read-only', severity: 'warning')
  end

  def blocking_warnings(warnings)
    warnings.select { |warning| warning[:severity] == 'blocking' }
  end

  def warning(code, message, severity: 'warning')
    { code: code, severity: severity, message: message }
  end

  def telephony_attribute(record, attr_name)
    return unless record&.has_attribute?(attr_name)

    record.public_send(attr_name)
  end

  def provider_config_hash(channel)
    (channel&.provider_config_hash || {}).with_indifferent_access
  rescue JSON::ParserError, TypeError
    {}.with_indifferent_access
  end

  def metadata_hash(binding)
    (binding&.metadata || {}).with_indifferent_access
  end

  def normalize_provider_kind(value)
    key = value.to_s.tr('-', '_').strip.downcase
    return 'asterisk_analog' if key.in?(%w[asterisk asterisk_analog analog asteriskanalog])
    return 'binotel' if key.include?('binotel')
    return 'sipuni' if key.include?('sipuni')

    PROVIDER_TEMPLATES.key?(key) ? key : nil
  end

  def infer_provider_kind(provider_config:, binding:)
    values = [
      provider_config[:number_ref],
      provider_config[:fonoster_number_ref],
      provider_config[:trunk_ref],
      binding&.number_ref,
      binding&.trunk_ref,
      provider_config[:provider_account_number],
      provider_config[:account_number]
    ].compact.join(' ').downcase

    return 'binotel' if values.include?('binotel')
    return 'sipuni' if values.include?('sipuni')
    return 'asterisk_analog' if values.include?('asterisk') || values.include?('analog')

    nil
  end

  def template_for(provider_kind)
    PROVIDER_TEMPLATES.fetch(provider_kind.to_s, UNKNOWN_PROVIDER_TEMPLATE)
  end

  def tel_url_number(value)
    normalize_technical_number(value)
  end

  def tel_url_for(value)
    normalized = normalize_technical_number(value)
    normalized.present? ? "tel:#{normalized}" : nil
  end

  def normalize_technical_number(value)
    value.to_s.strip.sub(/\A(?:tel:)+/i, '').presence
  end

  def normalize_tel_url(value)
    tel_url_for(value)
  end

  def first_present(*values)
    values.find { |value| value.present? }
  end

  def secret_key?(key)
    normalized = key.to_s
    return false if normalized.match?(/(_ref|ref)\z/i)
    return false if normalized.match?(/configured\z/i)

    normalized.match?(SECRET_KEY_PATTERN)
  end

  def redacted_value(value)
    value.present? ? '[REDACTED]' : nil
  end
end
