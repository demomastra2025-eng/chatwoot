# frozen_string_literal: true

class Whatsapp::HistoricalDeliveryCountsCache
  CACHE_TTL = 3.minutes
  CACHE_NAMESPACE = 'whatsapp:historical_delivery_counts:v1'
  FINGERPRINT_SQL = <<~SQL.squish
    COUNT(*),
    COALESCE(MAX(id), 0),
    COALESCE((EXTRACT(EPOCH FROM MAX(updated_at)) * 1000000)::bigint, 0)
  SQL

  def initialize(account:, eligible_channels:, period:, messages_scope:)
    @account = account
    @eligible_channels = eligible_channels
    @period = period
    @messages_scope = messages_scope
  end

  def fetch(count_keys:)
    key = cache_key
    cached = read_cache(key)
    return cached if cached

    computed = yield
    serialized = count_keys.index_with { |k| computed.fetch(k).to_h }
    write_cache(key, serialized)
    computed
  end

  private

  def read_cache(key)
    return if key.blank?

    Rails.cache.read(key)
  rescue StandardError => e
    Rails.logger.warn("[Whatsapp::HistoricalDeliveryCountsCache] cache read failed: #{e.class}: #{e.message}")
    nil
  end

  def write_cache(key, payload)
    return if key.blank?

    Rails.cache.write(key, payload, expires_in: CACHE_TTL)
  rescue StandardError => e
    Rails.logger.warn("[Whatsapp::HistoricalDeliveryCountsCache] cache write failed: #{e.class}: #{e.message}")
    nil
  end

  def cache_key
    channel_sig = @eligible_channels.map { |inbox, phone| "#{inbox.id}:#{phone}" }.sort.join(',')
    period_sig = "#{@period.begin.utc.to_i}:#{@period.end.utc.to_i}:#{@period.exclude_end? ? 'ex' : 'in'}"
    raw_version = "#{channel_sig}|#{period_sig}|#{messages_fingerprint}|#{deliveries_fingerprint}"
    digest = Digest::SHA256.hexdigest(raw_version)
    "#{CACHE_NAMESPACE}:acc=#{@account.id}:#{digest}"
  end

  def messages_fingerprint
    count, max_id, max_updated_usec = @messages_scope.pick(Arel.sql(FINGERPRINT_SQL))
    "#{count}:#{max_id}:#{max_updated_usec}"
  end

  def deliveries_fingerprint
    phones = @eligible_channels.map { |_, phone| phone }.uniq
    scope = WhatsappUsageDelivery.where(account_id: @account.id, phone_number: phones)
    count, max_id, max_updated_usec = scope.pick(Arel.sql(FINGERPRINT_SQL))
    "#{count}:#{max_id}:#{max_updated_usec}"
  end
end
