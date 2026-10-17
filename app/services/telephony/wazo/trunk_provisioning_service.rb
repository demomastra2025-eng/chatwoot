# frozen_string_literal: true

class Telephony::Wazo::TrunkProvisioningService
  OUTCALL_PATTERNS = [
    { exten: '_7XXXXXXXXXX', strip_digits: 0, external_prefix: '' },
    { exten: '_+7XXXXXXXXXX', strip_digits: 1, external_prefix: '' },
    { exten: '_87XXXXXXXXX', strip_digits: 1, external_prefix: '7' }
  ].freeze

  CARRIER_PRESETS = {
    'altel' => {
      label: 'Altel Business (АТС OneLink)',
      default_domain: 'astpbx.tele2.kz',
      default_host: '91.185.24.71',
      default_port: 5060,
      send_pai: false,
      registration_required: true
    },
    'tele2' => {
      label: 'Tele2 Business (АТС OneLink)',
      default_domain: 'astpbx.tele2.kz',
      default_host: '91.185.24.71',
      default_port: 5060,
      send_pai: false,
      registration_required: true
    },
    'kazakhtelecom' => {
      label: 'Казахтелеком iD Phone (АТС OneLink)',
      default_domain: 'sip.telecom.kz',
      default_host: 'sip.telecom.kz',
      default_port: 5060,
      send_pai: true,
      registration_required: true
    },
    'kcell' => {
      label: 'Kcell / Activ (АТС OneLink)',
      default_domain: 'sip.kcell.kz',
      default_host: 'sip.kcell.kz',
      default_port: 5060,
      send_pai: true,
      registration_required: true
    },
    'beeline_trunk' => {
      label: 'Билайн SIP-транк (АТС OneLink)',
      default_domain: 'sip.beeline.kz',
      default_host: 'sip.beeline.kz',
      default_port: 5060,
      send_pai: true,
      registration_required: true
    },
    'custom' => {
      label: 'Другой SIP-оператор (АТС OneLink)',
      default_domain: nil,
      default_host: nil,
      default_port: 5060,
      send_pai: false,
      registration_required: true
    }
  }.freeze

  def self.carrier_presets
    CARRIER_PRESETS.deep_dup
  end

  def initialize(
    client: Telephony::Wazo::ApiClient.new,
    incall_context: ENV.fetch('TELEPHONY_WAZO_INCALL_CONTEXT', nil),
    outcall_context: ENV.fetch('TELEPHONY_WAZO_OUTCALL_CONTEXT', nil)
  )
    @client = client
    @incall_context = incall_context.to_s.strip
    @outcall_context = outcall_context.to_s.strip
  end

  def provision_trunk!(
    did:,
    trunk_username:,
    trunk_password:,
    trunk_domain: nil,
    trunk_host: nil,
    trunk_port: nil,
    carrier_kind: 'custom',
    target_wazo_user_id: nil,
    target_wazo_group_id: nil
  )
    clean_did = sanitize_did(did)
    ensure_contexts_present!(clean_did)
    preset = CARRIER_PRESETS.fetch(carrier_kind.to_s.strip.downcase, CARRIER_PRESETS['custom'])
    resolved_domain = trunk_domain.to_s.strip.presence || preset[:default_domain]
    resolved_host = trunk_host.to_s.strip.presence || preset[:default_host] || resolved_domain
    resolved_port = (trunk_port.presence || preset[:default_port] || 5060).to_i

    if resolved_domain.blank? || resolved_host.blank?
      raise Telephony::Error.new(
        code: 'WAZO_TRUNK_DOMAIN_REQUIRED',
        message: 'SIP trunk domain and host are required for carrier provisioning',
        status: :unprocessable_content
      )
    end

    endpoint_uuid = upsert_trunk_endpoint!(
      clean_did: clean_did,
      trunk_username: trunk_username,
      trunk_password: trunk_password,
      trunk_domain: resolved_domain,
      trunk_host: resolved_host,
      trunk_port: resolved_port,
      send_pai: preset[:send_pai]
    )
    trunk_id = upsert_trunk_resource!(clean_did: clean_did, endpoint_uuid: endpoint_uuid)
    outcall_id = upsert_outcall_routing!(clean_did: clean_did, trunk_id: trunk_id)
    incall_id = if target_wazo_group_id.present? || target_wazo_user_id.present?
                  upsert_incall_routing!(
                    clean_did: clean_did,
                    target_wazo_user_id: target_wazo_user_id,
                    target_wazo_group_id: target_wazo_group_id
                  )
                end

    {
      did: clean_did,
      carrier_kind: CARRIER_PRESETS.key?(carrier_kind.to_s.strip.downcase) ? carrier_kind.to_s.strip.downcase : 'custom',
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

  def upsert_trunk_endpoint!(clean_did:, trunk_username:, trunk_password:, trunk_domain:, trunk_host:, trunk_port:, send_pai: false)
    name = "trunk_#{clean_did}"
    endpoint_options = [
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
    endpoint_options << ['send_pai', 'yes'] if send_pai

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
      endpoint_section_options: endpoint_options
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

  def upsert_trunk_resource!(endpoint_uuid:, clean_did: nil)
    _ = clean_did
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

  def upsert_incall_routing!(clean_did:, target_wazo_user_id: nil, target_wazo_group_id: nil)
    destination = if target_wazo_group_id.present?
                    { type: 'group', group_id: target_wazo_group_id.to_i, ring_time: 45 }
                  else
                    { type: 'user', user_id: target_wazo_user_id.to_i, ring_time: 45 }
                  end
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
