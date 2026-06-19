# frozen_string_literal: true

class Telephony::VirtualPbx::ConfigBuilder
  DEFAULT_PROVIDER_KIND = 'fonoster'
  MANAGED_BY_ONELINK = 'onelink'
  SECRET_KEY_PATTERN = /(password|secret|token|api[_-]?key|credential|auth)/i

  PROVIDER_TEMPLATES = {
    'asterisk_analog' => {
      label: 'Asterisk analog',
      default_transport: 'udp',
      default_port: 5060,
      allows_display_ingress_split: true,
      default_route_mode: 'operator'
    },
    'sipuni' => {
      label: 'Sipuni',
      default_transport: 'udp',
      default_port: 5060,
      allows_display_ingress_split: true,
      default_route_mode: 'operator'
    },
    DEFAULT_PROVIDER_KIND => {
      label: 'Fonoster',
      default_transport: 'udp',
      default_port: 5060,
      allows_display_ingress_split: false,
      default_route_mode: 'operator'
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
    unless channel.provider == 'fonoster'
      raise Telephony::Error.new(code: 'UNSUPPORTED_PROVIDER', message: 'Only Fonoster voice channels can be reconciled as Virtual PBX channels',
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
    routing = (config[:routing] || {}).with_indifferent_access
    ownership = (config[:ownership] || {}).with_indifferent_access
    provider_template = template_for(config[:provider_kind])

    {
      id: config[:id],
      inbox_id: config[:inbox_id],
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
        send_register: provider_connection[:send_register],
        configured: provider_connection.present? || phone_numbers[:ingress_number].present?,
        status: provider_connection[:status] || (config[:ready] ? 'ready' : 'action_required'),
        remote_mutations: remote_mutation_status(ownership),
        last_synced_at: first_present(resources[:last_synced_at], provider_connection[:last_synced_at])
      }.compact,
      routing: {
        mode: routing[:mode],
        fallback_mode: routing[:fallback_mode],
        ai_enabled: routing[:ai_enabled],
        operator_target_configured: routing[:operator_agent_aor].present? || routing[:operator_agent_ref].present?
      }.compact,
      employees: ui_employees_payload(config[:profiles]),
      permissions: {
        editable: !ownership[:read_only],
        remote_commit_allowed: !ownership[:read_only],
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
      remote_mutations: remote_mutation_status(ownership),
      last_synced_at: resources[:last_synced_at]
    }.compact
  end

  def remote_mutation_status(ownership)
    ownership[:read_only] ? 'blocked' : 'requires_approval'
  end

  def ui_status_label(status)
    case status
    when 'fonoster_synced'
      'Синхронизировано с телефонией'
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
      provider: channel.provider,
      provider_kind: provider_kind,
      provider_template: template_for(provider_kind),
      name: inbox.name,
      phone_numbers: parts.except(:provider_kind),
      resources: resources_payload(channel: channel, binding: binding, policy: policy),
      routing: routing_payload(binding: binding, policy: policy),
      profiles: profiles_payload(inbox: inbox, policy: policy),
      ownership: ownership_payload(channel: channel, binding: binding),
      provider_config: sanitize(provider_config_hash(channel)),
      metadata: sanitize(binding&.metadata || {}),
      ready: blocking_warnings(warnings).empty?,
      warnings: warnings
    }.compact
  end

  def phone_parts(channel:, binding:)
    provider_config = provider_config_hash(channel)
    metadata = metadata_hash(binding)
    provider_kind = normalize_provider_kind(
      first_present(
        provider_config[:provider_kind],
        metadata[:provider_kind],
        metadata[:source],
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
        provider_config[:account_number],
        metadata[:account_number]
      )
    )
    fonoster_tel_url = normalize_tel_url(
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
        binding&.ingress_number,
        provider_config[:ingress_number],
        metadata[:ingress_number],
        provider_config[:sipuni_ingress_number],
        metadata[:sipuni_ingress_number],
        tel_url_number(fonoster_tel_url),
        binding&.phone_number,
        provider_account_number,
        display_phone_number
      )
    )

    {
      provider_kind: provider_kind,
      display_phone_number: display_phone_number,
      provider_account_number: provider_account_number,
      ingress_number: ingress_number,
      fonoster_tel_url: fonoster_tel_url.presence || tel_url_for(ingress_number),
      display_matches_ingress: display_phone_number.present? && ingress_number.present? && display_phone_number == ingress_number,
      binding_represents_ingress: binding&.phone_number.present? && ingress_number.present? && binding.phone_number == ingress_number,
      legacy_channel_phone_differs_from_binding: channel.phone_number.present? && binding&.phone_number.present? &&
        channel.phone_number != binding.phone_number,
      split_allowed: template_for(provider_kind)[:allows_display_ingress_split]
    }.compact
  end

  def resources_payload(channel:, binding:, policy:)
    {
      inbox_id: channel.inbox&.id,
      channel_id: channel.id,
      number_binding_id: binding&.id,
      routing_policy_id: policy&.id,
      number_ref: binding&.number_ref,
      app_ref: binding&.configured_app_ref,
      runtime_app_ref: binding&.runtime_app_ref,
      trunk_ref: binding&.trunk_ref,
      provider_connection: binding&.provider_connection&.to_virtual_pbx_h,
      last_synced_at: binding&.last_synced_at,
      provisioning_status: telephony_attribute(binding, :provisioning_status),
      last_reconciled_at: telephony_attribute(binding, :last_reconciled_at),
      remote_drift_detected_at: telephony_attribute(binding, :remote_drift_detected_at),
      remote_drift_summary: telephony_attribute(binding, :remote_drift_summary)
    }.compact
  end

  def routing_payload(binding:, policy:)
    return {} if binding.blank? && policy.blank?

    {
      mode: policy&.mode,
      bridge_mode: policy&.bridge_mode,
      effective_app_ref: binding&.app_ref_for_policy(policy),
      operator_agent_ref: policy&.operator_agent_ref,
      operator_agent_aor: policy&.resolved_operator_agent_aor,
      fallback_mode: policy&.fallback_mode,
      ai_enabled: policy&.ai_enabled,
      ai_app_ref: policy&.effective_ai_app_ref
    }.compact
  end

  def profiles_payload(inbox:, policy:)
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
      warnings << legacy_ownership_warning(channel: channel, binding: binding)
    end.compact
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
    return 'sipuni' if key.include?('sipuni')

    PROVIDER_TEMPLATES.key?(key) ? key : DEFAULT_PROVIDER_KIND
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

    return 'sipuni' if values.include?('sipuni')
    return 'asterisk_analog' if values.include?('asterisk') || values.include?('analog')

    DEFAULT_PROVIDER_KIND
  end

  def template_for(provider_kind)
    PROVIDER_TEMPLATES.fetch(provider_kind, PROVIDER_TEMPLATES.fetch(DEFAULT_PROVIDER_KIND))
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
