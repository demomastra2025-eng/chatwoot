# frozen_string_literal: true

module Whatsapp::HistoricalDeliveryMetadata
  MAX_CONTENT_ATTRIBUTES_BYTES = 262_144

  private

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
