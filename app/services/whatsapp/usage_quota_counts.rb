# frozen_string_literal: true

module Whatsapp::UsageQuotaCounts
  FREE_SERVICE_TYPE = 'free_customer_service'
  FREE_ENTRY_POINT_TYPE = 'free_entry_point'
  REGULAR_TYPE = 'regular'

  module_function

  def classification(category:, billable:, pricing_type:)
    category = normalized_category(category)
    pricing_type = pricing_type.to_s.downcase.presence

    return :not_free if billable == true || known_non_free_type?(pricing_type)
    return :unknown if category.nil?
    return :not_free unless category == 'service'
    return :unknown if billable.nil?

    pricing_type == FREE_SERVICE_TYPE ? :free : :unknown
  end

  def known_non_free_type?(pricing_type)
    [FREE_ENTRY_POINT_TYPE, REGULAR_TYPE].include?(pricing_type)
  end

  def counts_by_phone(groups)
    free_counts = Hash.new(0)
    unknown_counts = Hash.new(0)

    groups.each do |(phone_number, category, billable, pricing_type), count|
      case classification(category: category, billable: billable, pricing_type: pricing_type)
      when :free
        free_counts[WhatsappUsageDelivery.canonical_phone_number(phone_number)] += count
      when :unknown
        unknown_counts[WhatsappUsageDelivery.canonical_phone_number(phone_number)] += count
      end
    end

    [free_counts, unknown_counts]
  end

  def normalized_category(value)
    category = value.to_s.downcase.strip
    category = 'authentication-international' if category == 'authentication_international'
    return if category.blank?

    category if WhatsappUsageDelivery::CATEGORY_VALUES.include?(category)
  end
end
