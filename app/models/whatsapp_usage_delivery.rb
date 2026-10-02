class WhatsappUsageDelivery < ApplicationRecord
  CATEGORY_VALUES = %w[service marketing utility authentication authentication-international referral_conversion].freeze

  validates :account_id, :phone_number, :provider_message_id, :received_at, presence: true

  def self.canonical_phone_number(value)
    value.to_s.gsub(/\D/, '')
  end

  def self.record_delivery!(inbox:, message:, status:)
    WhatsappUsageTrackingState.current_or_create!
    status = status.to_h.with_indifferent_access
    provider_message_id = status[:id].to_s
    phone_number = canonical_phone_number(inbox.channel.phone_number)
    return if phone_number.blank? || provider_message_id.blank?

    delivery = find_or_create_by!(phone_number: phone_number, provider_message_id: provider_message_id) do |record|
      assign_initial_delivery_attributes(record, inbox:, message:, status:)
    end

    fill_missing_delivery_metadata(delivery, status)
    delivery
  end

  def self.assign_initial_delivery_attributes(record, inbox:, message:, status:)
    metadata = provider_metadata(status)
    record.assign_attributes(
      account_id: inbox.account_id,
      message_id: message.id,
      inbox_id: inbox.id,
      delivered_at: metadata[:delivered_at],
      received_at: Time.current,
      category: metadata[:category],
      pricing_type: metadata[:pricing_type],
      pricing_model: metadata[:pricing_model],
      conversation_origin_type: metadata[:conversation_origin_type]
    )
    record.billable = metadata[:billable] if metadata[:billable_present]
  end
  private_class_method :assign_initial_delivery_attributes

  def self.fill_missing_delivery_metadata(delivery, status)
    metadata = provider_metadata(status)
    delivery.with_lock do
      updates = missing_delivery_attributes(delivery, metadata)
      updates[:billable] = metadata[:billable] if delivery.billable.nil? && metadata[:billable_present]
      delivery.update!(updates) if updates.present?
    end
  end
  private_class_method :fill_missing_delivery_metadata

  def self.missing_delivery_attributes(delivery, metadata)
    %i[delivered_at category pricing_type pricing_model conversation_origin_type].each_with_object({}) do |attribute, updates|
      value = metadata[attribute]
      updates[attribute] = value if delivery.public_send(attribute).blank? && value.present?
    end
  end
  private_class_method :missing_delivery_attributes

  def self.provider_metadata(status)
    pricing = status[:pricing].to_h.with_indifferent_access
    {
      delivered_at: delivered_timestamp(status),
      category: normalized_category(pricing[:category]),
      pricing_type: safe_metadata_value(pricing[:type]),
      pricing_model: safe_metadata_value(pricing[:pricing_model]),
      billable: boolean_value(pricing[:billable]),
      billable_present: pricing.key?(:billable),
      conversation_origin_type: status.dig(:conversation, :origin, :type).to_s.presence
    }
  end
  private_class_method :provider_metadata

  def self.delivered_timestamp(status)
    return unless status[:status].to_s == 'delivered'

    Whatsapp::ProviderTimestamp.time(status[:timestamp])
  end
  private_class_method :delivered_timestamp

  def self.normalized_category(value)
    category = value.to_s.downcase.strip
    category if CATEGORY_VALUES.include?(category)
  end
  private_class_method :normalized_category

  def self.safe_metadata_value(value)
    value.to_s.strip.presence&.slice(0, 64)
  end
  private_class_method :safe_metadata_value

  def self.boolean_value(value)
    return true if value == true || value.to_s.casecmp('true').zero?
    return false if value == false || value.to_s.casecmp('false').zero?

    nil
  end
  private_class_method :boolean_value
end
