# frozen_string_literal: true

class Whatsapp::HistoricalDeliveryCountsService
  include Whatsapp::HistoricalDeliveryMetadata

  Result = Struct.new(
    :delivery_groups,
    :free_quota_counts,
    :unknown_quota_counts,
    :unknown_existing_counts,
    :unknown_timestamp_counts,
    keyword_init: true
  )

  COUNT_KEYS = Result.members.freeze

  def initialize(account:, channels:, period:, now: Time.current)
    @account = account
    @channels = channels
    @period = period
    @now = now.utc
  end

  def perform
    return build_result(empty_counts) if @now < @period.begin || eligible_channels.empty?

    inbox_ids = eligible_channels.map { |inbox, _| inbox.id }.uniq
    cache = Whatsapp::HistoricalDeliveryCountsCache.new(
      account: @account, eligible_channels: eligible_channels,
      period: @period, messages_scope: base_eligible_messages_scope(inbox_ids)
    )
    build_result(cache.fetch(count_keys: COUNT_KEYS) { compute_counts })
  end

  private

  def compute_counts
    counts = empty_counts
    historical_message_candidates.each do |phone_number, candidates|
      count_phone_deliveries(phone_number, candidates, counts)
    end
    counts
  end

  def build_result(counts_hash)
    Result.new(**COUNT_KEYS.index_with { |key| Hash.new(0).merge!(counts_hash.fetch(key, {})) })
  end

  def eligible_channels
    @eligible_channels ||= Array(@channels).filter_map do |channel|
      inbox = channel.inbox
      phone_number = WhatsappUsageDelivery.canonical_phone_number(channel.phone_number)
      next if inbox.blank? || inbox.account_id != @account.id || phone_number.blank?

      [inbox, phone_number]
    end
  end

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
    eligible_channels.each do |inbox, phone_number|
      eligible_messages(inbox).reorder(:id).find_each do |message|
        add_message_candidate(candidates_by_key, phone_number, message)
      end
    end
    group_candidates_by_phone(candidates_by_key)
  end

  def add_message_candidate(candidates_by_key, phone_number, message)
    source_id = message.source_id.to_s
    return if source_id.blank?

    key = [phone_number, source_id]
    candidate = { source_id: source_id, metadata: message_metadata(message) }
    previous = candidates_by_key[key]
    return unless previous.nil? || metadata_score(candidate[:metadata]) > metadata_score(previous[:metadata])

    candidates_by_key[key] = candidate
  end

  def group_candidates_by_phone(candidates_by_key)
    grouped = Hash.new { |hash, key| hash[key] = [] }
    candidates_by_key.each do |(phone_number, _), candidate|
      grouped[phone_number] << candidate
    end
    grouped
  end

  def base_eligible_messages_scope(inbox_or_ids)
    Message.reorder(nil)
           .where(
             account_id: @account.id,
             inbox_id: inbox_or_ids,
             created_at: @period,
             message_type: [Message.message_types[:outgoing], Message.message_types[:template]],
             status: Message.statuses.values_at('delivered', 'read'),
             private: false
           )
           .where('messages.created_at <= ?', @now)
           .where.not(source_id: [nil, ''])
  end

  def eligible_messages(inbox)
    return Message.none if @now < @period.begin

    base_eligible_messages_scope(inbox.id)
      .without_imported_history
      .where(excluded_message_metadata_sql)
      .select(:id, :source_id, :content_attributes)
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
end
