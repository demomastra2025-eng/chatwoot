# frozen_string_literal: true

class Telephony::Wazo::CallLogSyncService
  PAGE_SIZE = 100
  MAX_PAGES = 100
  OVERLAP = 5.minutes
  INITIAL_LOOKBACK = 24.hours
  CURSOR_TTL = 2.days

  def initialize(connection:, client: nil)
    @connection = connection
    @client = client
  end

  def perform
    return unless ActiveModel::Type::Boolean.new.cast(ENV.fetch('TELEPHONY_WAZO_CALL_LOG_SYNC_ENABLED', nil))
    return unless connection.status == 'active' && connection.provider_kind == 'wazo'
    return unless connection.metadata.to_h['wazo_call_log_sync_enabled'] == true
    return if bindings.empty?
    raise 'Wazo CDR tenant is not configured' if ENV['TELEPHONY_WAZO_TENANT_UUID'].blank?

    extension = connection.metadata.to_h['wazo_call_log_sync_operator_extension'].to_s
    return if extension.blank?

    until_time = Time.current
    from = (Rails.cache.read(cursor_key) || (until_time - INITIAL_LOOKBACK)) - OVERLAP
    offset = 0
    skipped = 0

    MAX_PAGES.times do
      response = client.cdr(from: from, until_time: until_time, limit: PAGE_SIZE, offset: offset)
      rows = response['items'] if response.is_a?(Hash)
      raise 'Wazo CDR response has no items array' unless rows.is_a?(Array)

      rows.each { |row| skipped += 1 unless ingest(row, extension) }
      if rows.size < PAGE_SIZE
        Rails.cache.write(cursor_key, until_time, expires_in: CURSOR_TTL)
        Rails.logger.info("WAZO_CDR_SYNC connection_id=#{connection.id} skipped=#{skipped}")
        return
      end
      offset += PAGE_SIZE
    end
    Rails.logger.warn("WAZO_CDR_SYNC_PAGE_LIMIT connection_id=#{connection.id} skipped=#{skipped}")
  end

  private

  attr_reader :connection

  def client
    @client ||= Telephony::Wazo::ApiClient.new
  end

  def cursor_key
    "telephony:wazo:cdr:cursor:#{connection.id}"
  end

  def ingest(row, extension)
    return false unless row.is_a?(Hash)

    direction = row['direction'].to_s.downcase
    return false unless %w[inbound outbound].include?(direction)
    operator_extension = direction == 'inbound' ? row['destination_internal_exten'] : row['source_internal_exten']
    return false unless operator_extension.to_s == extension

    binding = find_binding(row, direction)
    return false unless binding

    profile = connection.sip_profiles.find_by(inbox_id: binding.inbox_id, internal_extension: extension, enabled: true)
    return false unless profile&.user_id

    started_at = parse_time(row['date'])
    ended_at = parse_time(row['date_end'])
    return false unless started_at && ended_at

    cdr_ref = row['conversation_id'].presence || row['id'].presence
    return false unless cdr_ref

    caller = normalize(direction == 'inbound' ? row['source_exten'] : row['destination_exten'])
    return false unless caller

    cdr_ref = "wazo:cdr:#{cdr_ref}"
    existing = Telephony::Wazo::CallLogCorrelator.find(
      account: connection.account, inbox: binding.inbox, caller: caller,
      did: normalize(binding.phone_number), direction: direction, started_at: started_at,
      cdr_ref: cdr_ref
    )
    answered_at = parse_time(row['date_answer'])
    voicemail = ActiveModel::Type::Boolean.new.cast(row['reached_voicemail'])
    answered_at = nil if voicemail
    status = if answered_at
               'completed'
             elsif direction == 'inbound'
               'missed'
             else
               'no_answer'
             end
    payload = {
      account_id: connection.account_id,
      inbox_id: binding.inbox_id,
      call_ref: existing&.external_call_ref || cdr_ref,
      event_key: "#{cdr_ref}:final",
      event: status,
      status: status,
      provider: 'wazo',
      direction: direction,
      number_ref: binding.number_ref,
      from_number: direction == 'inbound' ? caller : normalize(binding.phone_number),
      to_number: direction == 'inbound' ? normalize(binding.phone_number) : caller,
      started_at: started_at.iso8601,
      answered_at: answered_at&.iso8601,
      answered_by: ("user:#{profile.user_id}" if answered_at),
      ended_at: ended_at.iso8601,
      occurred_at: ended_at.iso8601,
      duration: (ended_at - (answered_at || started_at)).to_i.clamp(0, 86_400),
      end_reason: ('voicemail' if voicemail),
      metadata: {
        wazo_cdr_ref: cdr_ref,
        reached_voicemail: voicemail,
        chatwoot_user_id: profile.user_id
      }
    }.compact
    session = Telephony::EventsIngestionService.new(payload: payload).perform
    raise 'Wazo CDR ingestion did not produce a call session' unless session
    event = connection.account.telephony_events.find_by(event_key: payload[:event_key])
    raise 'Wazo CDR ingestion did not complete' unless event&.processed?

    true
  end

  def find_binding(row, direction)
    candidates = if direction == 'inbound'
                   row.values_at('requested_exten', 'destination_exten')
                 else
                   row.values_at('source_line_identity', 'source_exten', 'requested_exten', 'destination_exten')
                 end
    dids = candidates.filter_map { |value| normalize(value) }.uniq
    bindings.find do |binding|
      dids.include?(normalize(binding.phone_number)) || dids.include?(normalize(binding.ingress_number))
    end
  end

  def bindings
    @bindings ||= Telephony::NumberBinding.includes(:inbox).where(account_id: connection.account_id, provider: 'wazo').select do |binding|
      binding.provider_connection_id == connection.id ||
        binding.voice_channel&.provider_config_hash.to_h['provider_connection_id'].to_i == connection.id
    end
  end

  def normalize(value)
    Contacts::PhoneNumberNormalizer.normalize(value) ||
      Contacts::PhoneNumberNormalizer.normalize(value, default_country: 'KZ')
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError, TypeError
    nil
  end
end
