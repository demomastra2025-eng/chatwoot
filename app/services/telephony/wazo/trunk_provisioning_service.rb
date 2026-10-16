# frozen_string_literal: true

class Telephony::Wazo::TrunkProvisioningService
  OUTCALL_PATTERNS = [
    { exten: '_7XXXXXXXXXX', strip_digits: 0, external_prefix: '' },
    { exten: '_+7XXXXXXXXXX', strip_digits: 1, external_prefix: '' },
    { exten: '_87XXXXXXXXX', strip_digits: 1, external_prefix: '7' }
  ].freeze

  def initialize(
    client: Telephony::Wazo::ApiClient.new,
    incall_context: ENV.fetch('TELEPHONY_WAZO_INCALL_CONTEXT', nil),
    outcall_context: ENV.fetch('TELEPHONY_WAZO_OUTCALL_CONTEXT', nil)
  )
    @client = client
    @incall_context = incall_context.to_s.strip
    @outcall_context = outcall_context.to_s.strip
  end

  def provision_trunk!(did:, trunk_username:, trunk_password:, trunk_domain:, trunk_host: nil, trunk_port: 5060, target_wazo_user_id: nil)
    clean_did = sanitize_did(did)
    ensure_contexts_present!(clean_did)

    endpoint_uuid = upsert_trunk_endpoint!(
      clean_did: clean_did,
      trunk_username: trunk_username,
      trunk_password: trunk_password,
      trunk_domain: trunk_domain,
      trunk_host: trunk_host.presence || trunk_domain,
      trunk_port: trunk_port
    )
    trunk_id = upsert_trunk_resource!(clean_did: clean_did, endpoint_uuid: endpoint_uuid)
    outcall_id = upsert_outcall_routing!(clean_did: clean_did, trunk_id: trunk_id)
    incall_id = upsert_incall_routing!(clean_did: clean_did, target_wazo_user_id: target_wazo_user_id) if target_wazo_user_id.present?

    {
      did: clean_did,
      trunk_endpoint_uuid: endpoint_uuid,
      trunk_id: trunk_id,
      outcall_id: outcall_id,
      incall_id: incall_id
    }.compact
  end

  private

  attr_reader :client, :incall_context, :outcall_context

  def sanitize_did(did)
    digits = did.to_s.gsub(/\D/, '')
    digits = "7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
    raise Telephony::Error.new(code: 'WAZO_TRUNK_DID_INVALID', message: 'Valid DID phone number is required', status: :unprocessable_content) if digits.blank?

    digits
  end

  def ensure_contexts_present!(clean_did)
    return if incall_context.present? && outcall_context.present? && clean_did.present?

    raise Telephony::Error.new(
      code: 'WAZO_TRUNK_CONTEXT_NOT_CONFIGURED',
      message: 'Wazo incall and outcall contexts must be configured for trunk provisioning',
      status: :service_unavailable
    )
  end

  def upsert_trunk_endpoint!(clean_did:, trunk_username:, trunk_password:, trunk_domain:, trunk_host:, trunk_port:)
    name = "trunk_#{clean_did}"
    payload = {
      name: name,
      label: "OneLink Trunk #{clean_did}",
      aor_section_options: [
        ['contact', "sip:#{trunk_username}@#{trunk_host}:#{trunk_port}"],
        ['qualify_frequency', '30']
      ],
      outbound_auth_section_options: [
        ['username', trunk_username.to_s],
        ['password', trunk_password.to_s]
      ],
      endpoint_section_options: [
        ['context', incall_context],
        ['transport', 'transport-udp'],
        ['from_user', trunk_username.to_s],
        ['from_domain', trunk_domain.to_s],
        ['disallow', 'all'],
        ['allow', 'alaw,ulaw,opus'],
        ['direct_media', 'no'],
        ['rtp_symmetric', 'yes'],
        ['force_rport', 'yes'],
        ['rewrite_contact', 'yes']
      ]
    }
    existing = client.sip_endpoints.find { |ep| ep['name'] == name }
    if existing
      client.update_sip_endpoint(existing['uuid'], payload)
      existing['uuid']
    else
      created = client.create_sip_endpoint(payload)
      created.fetch('uuid')
    end
  end

  def upsert_trunk_resource!(clean_did:, endpoint_uuid:)
    existing = client.trunks.find { |t| t.dig('endpoint_sip', 'uuid') == endpoint_uuid }
    trunk_id = if existing
                 existing.fetch('id')
               else
                 created = client.create_trunk(context: incall_context)
                 created.fetch('id')
               end
    client.associate_trunk_sip_endpoint(trunk_id, endpoint_uuid)
    trunk_id
  end

  def upsert_outcall_routing!(clean_did:, trunk_id:)
    name = "onelink-outcall-#{clean_did}"
    existing = client.outcalls.find { |o| o['name'] == name }
    outcall_id = if existing
                   existing.fetch('id')
                 else
                   created = client.create_outcall(name: name, description: "OneLink outbound for #{clean_did}")
                   created.fetch('id')
                 end
    client.associate_outcall_trunks(outcall_id, [trunk_id])

    existing_exts = client.extensions.select { |e| e['context'] == outcall_context }.index_by { |e| e['exten'] }
    OUTCALL_PATTERNS.each do |pattern|
      ext = existing_exts[pattern[:exten]] || client.create_extension(context: outcall_context, exten: pattern[:exten])
      client.associate_outcall_extension(
        outcall_id,
        ext.fetch('id'),
        caller_id: clean_did,
        strip_digits: pattern[:strip_digits],
        external_prefix: pattern[:external_prefix]
      )
    end
    outcall_id
  end

  def upsert_incall_routing!(clean_did:, target_wazo_user_id:)
    destination = { type: 'user', user_id: target_wazo_user_id.to_i, ring_time: 45 }
    existing = client.incalls.find do |inc|
      Array(inc['extensions']).any? { |e| e['exten'].to_s == clean_did }
    end

    if existing
      client.update_incall(existing.fetch('id'), destination: destination)
      return existing.fetch('id')
    end

    incall = client.create_incall(destination: destination, description: "OneLink DID #{clean_did}")
    incall_id = incall.fetch('id')
    ext = client.extensions.find { |e| e['context'] == incall_context && e['exten'].to_s == clean_did } ||
          client.create_extension(context: incall_context, exten: clean_did)
    client.associate_incall_extension(incall_id, ext.fetch('id'))
    incall_id
  end
end
