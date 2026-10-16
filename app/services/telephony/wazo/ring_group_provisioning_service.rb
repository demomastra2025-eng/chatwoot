# frozen_string_literal: true

class Telephony::Wazo::RingGroupProvisioningService
  STRATEGIES = %w[all least_recent fewest_calls memorized_round_robin random weight_random linear].freeze

  def initialize(account:, inbox:, client: Telephony::Wazo::ApiClient.new, sip_context: ENV.fetch('TELEPHONY_WAZO_SIP_CONTEXT', nil))
    @account = account
    @inbox = inbox
    @client = client
    @sip_context = sip_context.to_s.strip
  end

  def sync!(ring_strategy: 'all', timeout: 45, user_timeout: 25, retry_delay: 5, group_extension: nil, bind_incalls: true)
    validate_strategy!(ring_strategy)
    group = upsert_group!(ring_strategy: ring_strategy, timeout: timeout, user_timeout: user_timeout, retry_delay: retry_delay)
    group_uuid = group.fetch('uuid')
    group_id = group.fetch('id')

    member_uuids = active_wazo_user_uuids
    users_payload = member_uuids.each_with_index.map { |uuid, idx| { uuid: uuid, priority: idx + 1 } }
    client.update_group_user_members(group_uuid, users_payload)

    ext_id = sync_group_extension!(group_uuid, group_extension) if group_extension.present?
    bound_incall_ids = bind_inbox_incalls_to_group!(group_id, timeout) if bind_incalls

    {
      group_id: group_id,
      group_uuid: group_uuid,
      group_label: group_label,
      ring_strategy: ring_strategy,
      member_user_uuids: member_uuids,
      group_extension: group_extension.presence,
      group_extension_id: ext_id,
      bound_incall_ids: bound_incall_ids || []
    }.compact
  end

  private

  attr_reader :account, :inbox, :client, :sip_context

  def validate_strategy!(strategy)
    return if STRATEGIES.include?(strategy.to_s)

    raise Telephony::Error.new(
      code: 'WAZO_GROUP_STRATEGY_INVALID',
      message: "Unsupported Wazo ring group strategy: #{strategy}",
      status: :unprocessable_content
    )
  end

  def group_label
    "OneLink Inbox #{inbox.id}"
  end

  def upsert_group!(ring_strategy:, timeout:, user_timeout:, retry_delay:)
    payload = {
      label: group_label,
      ring_strategy: ring_strategy.to_s,
      timeout: timeout.to_i,
      user_timeout: user_timeout.to_i,
      retry_delay: retry_delay.to_i,
      ring_in_use: false
    }
    existing = client.groups.find { |g| g['label'] == group_label }
    if existing
      client.update_group(existing.fetch('uuid'), payload)
      existing
    else
      client.create_group(payload)
    end
  end

  def active_wazo_user_uuids
    inbox.telephony_sip_profiles
         .where(status: 'active', enabled: true)
         .filter_map { |profile| profile.metadata.to_h['wazo_user_uuid'].presence }
         .uniq
  end

  def sync_group_extension!(group_uuid, group_extension)
    if sip_context.blank?
      raise Telephony::Error.new(
        code: 'WAZO_SIP_CONTEXT_NOT_CONFIGURED',
        message: 'Wazo SIP context is required to bind a ring group extension',
        status: :service_unavailable
      )
    end

    ext = client.extensions.find { |e| e['context'] == sip_context && e['exten'].to_s == group_extension.to_s } ||
          client.create_extension(context: sip_context, exten: group_extension.to_s)
    ext_id = ext.fetch('id')
    client.associate_group_extension(group_uuid, ext_id)
    ext_id
  end

  def bind_inbox_incalls_to_group!(group_id, timeout)
    dids = inbox_clean_dids
    return [] if dids.empty?

    destination = { type: 'group', group_id: group_id, ring_time: timeout.to_i }
    matching_incalls = client.incalls.select do |inc|
      Array(inc['extensions']).any? { |e| dids.include?(sanitize_did(e['exten'])) }
    end

    matching_incalls.map do |inc|
      inc_id = inc.fetch('id')
      client.update_incall(inc_id, destination: destination)
      inc_id
    end
  end

  def inbox_clean_dids
    Telephony::NumberBinding.where(account_id: account.id, inbox_id: inbox.id)
                            .flat_map { |b| [sanitize_did(b.phone_number), sanitize_did(b.ingress_number)] }
                            .compact_blank.uniq
  end

  def sanitize_did(value)
    digits = value.to_s.gsub(/\D/, '')
    digits = "7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
    digits
  end
end
