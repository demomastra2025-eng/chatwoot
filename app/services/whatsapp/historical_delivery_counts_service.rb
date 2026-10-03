# frozen_string_literal: true

class Whatsapp::HistoricalDeliveryCountsService
  Result = Struct.new(
    :delivery_groups,
    :free_quota_counts,
    :unknown_quota_counts,
    :unknown_existing_counts,
    :unknown_timestamp_counts,
    keyword_init: true
  )

  MAX_CONTENT_ATTRIBUTES_BYTES = 262_144

  def initialize(account:, channels:, period:, now: Time.current)
    @account = account
    @channels = channels
    @period = period
    @now = now.utc
  end

  def perform
    counts = empty_counts
    historical_message_candidates.each do |phone_number, candidates|
      count_phone_deliveries(phone_number, candidates, counts)
    end
    Result.new(**counts)
  end

  private

  def empty_counts
    {
      delivery_groups: Hash.new(0),
      free_quota_counts: Hash.new(0),
      unknown_quota_counts: Hash.new(0),
      unknown_existing_counts: Hash.new(0),
      unknown_timestamp_counts: Hash.new(0)
    }
  end

  def count_phone_deliveries(phone_number, candidates, counts)
    deliveries = delivery_metadata_by_id(matching_deliveries(phone_number, candidates))
    candidates.each do |candidate|
      count_candidate(phone_number, candidate, deliveries, counts)
    end
  end

  def count_candidate(phone_number, candidate, deliveries, counts)
    source_id = candidate[:source_id]
    delivery = deliveries[source_id]
    counts[:unknown_existing_counts][phone_number] += 1 unless delivery
    return if delivery&.dig(:delivered_at).present?

    metadata = merge_delivery_metadata(candidate[:metadata], delivery)
    add_delivery_count(phone_number, metadata, counts)
    counts[:unknown_timestamp_counts][phone_number] += 1
    add_quota_count(phone_number, metadata, counts)
  end

  def add_delivery_count(phone_number, metadata, counts)
    key = [phone_number, metadata[:category], metadata[:billable], metadata[:recipient_country]]
    counts[:delivery_groups][key] += 1
  end

  def add_quota_count(phone_number, metadata, counts)
    classification = Whatsapp::UsageQuotaCounts.classification(
      category: metadata[:category], billable: metadata[:billable], pricing_type: metadata[:pricing_type]
    )
    return if classification == :not_free

    count_key = classification == :free ? :free_quota_counts : :unknown_quota_counts
    counts[count_key][phone_number] += 1
  end

  def historical_message_candidates
    candidates_by_key = {}
    @channels.each { |channel| add_channel_candidates(candidates_by_key, channel) }
    group_candidates_by_phone(candidates_by_key)
  end

  def add_channel_candidates(candidates_by_key, channel)
    inbox = channel.inbox
    phone_number = WhatsappUsageDelivery.canonical_phone_number(channel.phone_number)
    return if inbox.blank? || inbox.account_id != @account.id || phone_number.blank?

    eligible_messages(inbox).reorder(:id).find_each do |message|
      add_message_candidate(candidates_by_key, phone_number, message)
    end
  end

  def add_message_candidate(candidates_by_key, phone_number, message)
    source_id = message.source_id.to_s
    return if source_id.blank?

    key = [phone_number, source_id]
    candidate = { source_id: source_id, metadata: message_metadata(message) }
    previous = candidates_by_key[key]
    if previous.nil? || metadata_score(candidate[:metadata]) > metadata_score(previous[:metadata])
      candidates_by_key[key] = candidate
    end
  end

  def group_candidates_by_phone(candidates_by_key)
    grouped = Hash.new { |hash, key| hash[key] = [] }
    candidates_by_key.each do |(phone_number, _), candidate|
      grouped[phone_number] << candidate
    end
    grouped
  end

  def eligible_messages(inbox)
    return Message.none if @now < @period.begin

    Message.without_imported_history
      .select(:id, :source_id, :content_attributes)
      .where(
        account_id: @account.id,
        inbox_id: inbox.id,
        created_at: @period,
        message_type: [Message.message_types[:outgoing], Message.message_types[:template]],
        status: Message.statuses.values_at('delivered', 'read'),
        private: false
      )
      .where('messages.created_at <= ?', @now)
      .where.not(source_id: [nil, ''])
      .where(excluded_message_metadata_sql)
  end

  def excluded_message_metadata_sql
    <<~'SQL'.squish
      NOT CASE json_typeof(messages.content_attributes)
      WHEN 'object' THEN
        LOWER(COALESCE(messages.content_attributes ->> 'external_echo', 'false')) = 'true'
        OR LOWER(COALESCE(messages.content_attributes ->> 'whatsapp_history_import', 'false')) = 'true'
      WHEN 'string' THEN
        COALESCE(messages.content_attributes #>> '{}', '') ~*
          '"(external_echo|whatsapp_history_import)"\s*:\s*(true|"true")'
      ELSE false
      END
    SQL
  end

  def matching_deliveries(phone_number, candidates)
    WhatsappUsageDelivery.where(
      account_id: @account.id,
      phone_number: phone_number,
      provider_message_id: candidates.pluck(:source_id)
    ).pluck(:provider_message_id, :delivered_at, :category, :billable, :pricing_type, :recipient_country)
  end

  def delivery_metadata_by_id(delivery_rows)
    delivery_rows.each_with_object({}) do |row, deliveries|
      provider_message_id, delivered_at, category, billable, pricing_type, recipient_country = row
      deliveries[provider_message_id] = {
        delivered_at: delivered_at,
        category: category,
        billable: billable,
        pricing_type: pricing_type,
        recipient_country: recipient_country
      }
    end
  end

  def merge_delivery_metadata(message_metadata, delivery_row)
    return message_metadata unless delivery_row

    metadata = message_metadata.dup
    %i[category billable pricing_type recipient_country].each do |key|
      value = delivery_row[key]
      metadata[key] = value if !value.nil? && (key == :billable || value.present?)
    end
    metadata
  end

  def message_metadata(message)
    raw_attributes = message.read_attribute_before_type_cast(:content_attributes)
    attributes = safe_hash(raw_attributes)
    delivery = safe_hash(attributes['whatsapp_delivery'])
    pricing = safe_hash(delivery['pricing'])

    {
      category: normalized_category(pricing['category']),
      pricing_type: normalized_pricing_type(pricing['type']),
      billable: normalized_boolean(pricing['billable']),
      recipient_country: normalized_country(delivery['recipient_country'])
    }
  end

  def safe_hash(value)
    return value.deep_stringify_keys if value.is_a?(Hash)
    return {} unless bounded_json_string?(value)

    parsed_json_hash(value)
  rescue JSON::ParserError, TypeError
    {}
  end

  def parsed_json_hash(value)
    parsed = JSON.parse(value)
    parsed = JSON.parse(parsed) if bounded_json_string?(parsed)
    parsed.is_a?(Hash) ? parsed.deep_stringify_keys : {}
  end

  def bounded_json_string?(value)
    value.is_a?(String) && value.bytesize <= MAX_CONTENT_ATTRIBUTES_BYTES
  end

  def metadata_score(metadata)
    %i[category pricing_type billable].count { |key| !metadata[key].nil? }
  end

  def normalized_category(value)
    Whatsapp::UsageQuotaCounts.normalized_category(value)
  end

  def normalized_pricing_type(value)
    type = value.to_s.downcase.strip
    type if %w[regular free_customer_service free_entry_point].include?(type)
  end

  def normalized_boolean(value)
    return true if value == true || value.to_s.casecmp('true').zero?
    return false if value == false || value.to_s.casecmp('false').zero?

    nil
  end

  def normalized_country(value)
    country = value.to_s.upcase
    country if country.match?(/\A[A-Z]{2}\z/)
  end
end
