# frozen_string_literal: true

class Telephony::Binotel::NativeWebphoneCorrelator
  TERMINAL_CORRELATION_WINDOW = 30.minutes
  CREATED_SKEW = 30.seconds

  def initialize(attributes)
    @account_id = attributes[:account_id]
    @inbox_id = attributes[:inbox_id]
    @started_at = attributes[:started_at]
    @ended_at = attributes[:ended_at]
    @received_at = attributes[:received_at]
    @from_number = attributes[:from_number]
    @to_number = attributes[:to_number]
    @direction = attributes[:direction]
  end

  def call_session
    records = candidates.compact.uniq(&:id).sort_by { |record| start_distance(record) }
    return records.first if records.one?
    return if records.blank? || start_distance(records.first) == start_distance(records.second)

    records.first
  end

  private

  attr_reader :account_id, :inbox_id, :started_at, :ended_at, :received_at, :from_number, :to_number, :direction

  def candidates
    return [] if account_id.blank? || inbox_id.blank? || started_at.blank?
    return [] if from_number.blank? || to_number.blank?
    return [] unless direction.in?(%w[inbound outbound])

    candidate_scope.where(from_number: phone_variants(from_number), to_number: phone_variants(to_number)).limit(20).to_a
  end

  def candidate_scope
    Telephony::CallSession
      .where(
        account_id: account_id,
        inbox_id: inbox_id,
        provider: 'binotel',
        direction: direction
      )
      .where('external_call_ref LIKE ?', external_call_ref_pattern)
      .where(provider_call_sid: [nil, ''])
      .where(
        'COALESCE(started_at, created_at) BETWEEN ? AND ?',
        correlation_window_start,
        correlation_window_end
      )
  end

  def correlation_window_start
    direction == 'inbound' ? started_at - CREATED_SKEW : started_at - TERMINAL_CORRELATION_WINDOW
  end

  def correlation_window_end
    return started_at + CREATED_SKEW unless direction == 'inbound'

    [ended_at, received_at].compact.min || started_at
  end

  def external_call_ref_pattern
    direction == 'inbound' ? 'binotel:janus:%' : 'binotel:local:%'
  end

  def start_distance(record)
    (started_at - (record.started_at || record.created_at)).abs
  end

  def phone_variants(value)
    normalized = normalize_phone(value)
    [value.to_s, normalized, value.to_s.delete_prefix('+'), normalized&.delete_prefix('+')].compact_blank.uniq
  end

  def normalize_phone(value)
    Contacts::PhoneNumberNormalizer.normalize(value) ||
      Contacts::PhoneNumberNormalizer.normalize(value, default_country: 'KZ')
  end
end
