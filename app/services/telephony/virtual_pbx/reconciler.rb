# frozen_string_literal: true

class Telephony::VirtualPbx::Reconciler
  PROVIDER_OWNED_ROUTING_KINDS = %w[sipuni binotel].freeze
  PROVIDER_EXTENSION_MODES = %w[external_extension provider_extension].freeze

  def initialize(account:, resource_client: nil)
    @account = account
    @resource_client = resource_client
  end

  def check(desired_state)
    state = desired_state.with_indifferent_access
    refs = (state[:refs] || {}).with_indifferent_access
    drift = []
    remote_snapshot = {}

    number = fetch_resource(:number, refs[:number_ref], drift, 'remote_number_missing')
    remote_snapshot[:number] = number if number.present?
    if number.present?
      drift.concat(number_drift(state, number))
      drift << drift_item('remote_number_unowned', 'Remote number is not owned by OneLink') unless onelink_owned?(state, number)
    end

    if refs[:trunk_ref].present?
      trunk = fetch_resource(:trunk, refs[:trunk_ref], drift, 'remote_trunk_missing')
      remote_snapshot[:trunk] = trunk if trunk.present?
    end

    profile_resources = profile_remote_resources(state, drift)
    remote_snapshot[:agents] = profile_resources if profile_resources.present?

    status = drift.empty? ? 'fonoster_synced' : 'requires_manual_reconcile'
    update_local_reconcile_state!(state, status: status, drift: drift)

    {
      status: status,
      ready: drift.empty?,
      drift: drift,
      remote_snapshot: Telephony::VirtualPbx::BridgeResourceClient.sanitize_payload(remote_snapshot)
    }
  rescue Telephony::Error => e
    drift = [drift_item(e.code.to_s.downcase, e.message)]
    update_local_reconcile_state!(desired_state.with_indifferent_access, status: 'remote_failed', drift: drift)
    { status: 'remote_failed', ready: false, drift: drift, errors: [{ code: e.code, message: e.message }] }
  end

  private

  attr_reader :account, :resource_client

  def client
    @client ||= resource_client || Telephony::VirtualPbx::BridgeResourceClient.new(
      bridge_client: Telephony::BridgeClient.new(account_id: account.id)
    )
  end

  def fetch_resource(method, ref, drift, missing_code)
    return if ref.blank?

    client.public_send(method, ref)
  rescue Telephony::Error => e
    raise unless e.code == 'REMOTE_RESOURCE_NOT_FOUND'

    drift << drift_item(missing_code, e.message)
    nil
  end

  def number_drift(state, number)
    phone_numbers = (state[:phone_numbers] || {}).with_indifferent_access
    refs = (state[:refs] || {}).with_indifferent_access
    routing = (state[:routing] || {}).with_indifferent_access
    actual = number.with_indifferent_access
    actual_metadata = (actual[:metadata] || {}).with_indifferent_access
    actual_route = (actual[:route] || actual[:routeState] || actual[:route_state] || {}).with_indifferent_access
    actual_route_headers = Array.wrap(actual_route[:extra_headers] || actual_route[:extraHeaders])

    [].tap do |items|
      expected_tel = phone_numbers[:fonoster_tel_url]
      actual_tel = actual[:telUrl] || actual[:tel_url]
      if expected_tel.present? && actual_tel.to_s != expected_tel.to_s
        items << drift_item('remote_tel_url_mismatch', 'Remote telUrl does not match OneLink ingress')
      end
      actual_trunk = actual[:trunkRef] || actual[:trunk_ref] || actual.dig(:trunk, :ref) || actual.dig('trunk', 'ref')
      if refs[:trunk_ref].present? && actual_trunk.to_s != refs[:trunk_ref].to_s
        items << drift_item('remote_trunk_ref_mismatch', 'Remote trunkRef does not match OneLink provider connection')
      end
      expected_mode = routing[:bridge_mode] || routing[:mode]
      actual_mode = actual_route[:mode] || actual_metadata[:routing_mode] || header_value(actual_route_headers, 'x-onelink-mode')
      if expected_mode.present? && actual_mode.present? && actual_mode.to_s != expected_mode.to_s
        items << drift_item('remote_route_mode_mismatch', 'Remote route mode does not match OneLink routing')
      end
      expected_app = routing[:app_ref] || refs[:runtime_app_ref] || refs[:app_ref]
      actual_app = actual_route[:app_ref] || actual_route[:appRef] ||
                   actual_metadata[:app_ref] || actual_metadata[:appRef] ||
                   actual[:app_ref] || actual[:appRef] ||
                   header_value(actual_route_headers, 'x-app-ref')
      if expected_app.present? && actual_app.to_s != expected_app.to_s
        items << drift_item('remote_runtime_app_mismatch', 'Remote runtime app does not match OneLink routing')
      end
    end
  end

  def profile_remote_resources(state, drift)
    Array.wrap(state[:profiles]).filter_map do |profile|
      attrs = profile.with_indifferent_access
      next if provider_managed_extension_profile?(state, attrs)
      next if attrs[:agent_ref].blank?

      agent = fetch_resource(:agent, attrs[:agent_ref], drift, 'remote_agent_missing')
      drift.concat(agent_drift(attrs, agent)) if agent.present?
      agent
    end
  end

  def provider_managed_extension_profile?(state, attrs)
    provider_kind = state[:provider_kind].to_s
    availability_mode = attrs[:availability_mode].to_s

    return true if provider_kind.in?(PROVIDER_OWNED_ROUTING_KINDS) && PROVIDER_EXTENSION_MODES.include?(availability_mode)
    return true if provider_kind == 'asterisk_analog' && PROVIDER_EXTENSION_MODES.include?(availability_mode)

    false
  end

  def agent_drift(profile, agent)
    attrs = profile.with_indifferent_access
    actual = agent.with_indifferent_access
    [].tap do |items|
      expected_aor = attrs[:agent_aor]
      actual_aor = actual[:agent_aor] || actual[:agentAor] || actual[:aor]
      if expected_aor.present? && actual_aor.present? && actual_aor.to_s != expected_aor.to_s
        items << drift_item('remote_agent_aor_mismatch', 'Remote employee agent route does not match OneLink extension')
      end
      expected_credentials_ref = attrs[:fonoster_credentials_ref].presence || attrs[:credentials_ref].presence
      actual_credentials_ref = actual[:credentialsRef] ||
                               actual[:credentials_ref] ||
                               actual.dig(:credentials, :ref) ||
                               actual.dig('credentials', 'ref')
      if expected_credentials_ref.present? && actual_credentials_ref.to_s != expected_credentials_ref.to_s
        items << drift_item('remote_agent_credentials_mismatch', 'Remote employee agent credentials do not match OneLink SIP profile')
      end
      next unless attrs.key?(:enabled) && actual.key?(:enabled)

      expected_enabled = ActiveModel::Type::Boolean.new.cast(attrs[:enabled])
      actual_enabled = ActiveModel::Type::Boolean.new.cast(actual[:enabled])
      if expected_enabled != actual_enabled
        items << drift_item('remote_agent_enabled_mismatch', 'Remote employee agent enabled state does not match OneLink')
      end
    end
  end

  def onelink_owned?(state, number)
    metadata = (number.with_indifferent_access[:metadata] || {}).with_indifferent_access
    return false if metadata[:managed_by].present? && metadata[:managed_by] != 'onelink'
    return true if metadata[:managed_by] == 'onelink' && metadata[:onelink_account_id].to_s == state[:account_id].to_s

    state.dig(:ownership, :managed_by) == 'onelink'
  end

  def update_local_reconcile_state!(state, status:, drift:)
    attrs = {
      provisioning_status: status,
      last_reconciled_at: Time.current,
      remote_drift_detected_at: drift.present? ? Time.current : nil,
      remote_drift_summary: drift
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

  def drift_item(code, message)
    { code: code, message: message, severity: 'blocking' }
  end

  def header_value(headers, name)
    headers.find { |header| header.with_indifferent_access[:name].to_s.casecmp?(name) }
           &.with_indifferent_access
           &.dig(:value)
  end
end
