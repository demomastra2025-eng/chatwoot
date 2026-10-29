module Contacts::IinPrivacy
  PERMISSION = 'contact_iin_view'.freeze
  MASKED_IIN = '••••••••••••'.freeze
  TWELVE_DIGITS_REGEX = /\A\d{12}\z/
  EMBEDDED_TWELVE_DIGITS_REGEX = /(?:\A|\D)\d{12}(?:\D|\z)/
  MASKED_PLACEHOLDER_REGEX = /\A[•*]{6,}\z/
  EXPLICIT_IIN_KEYS = %w[iin medelement_iin].freeze
  REALTIME_EXPLICIT_IIN_KEYS = %w[iin medelement_iin iin_masked].freeze
  CONTACT_REALTIME_PARENTS = %w[contact contacts sender channel_profile channel_profiles].freeze
  FILTER_IIN_ATTRIBUTE_KEYS = %w[identifier iin medelement_iin].freeze

  module_function

  def can_view_iin?(account_user: Current.account_user)
    return true if account_user.nil? || account_user.administrator? || account_user.custom_role_id.blank?

    Array(account_user.permissions).include?(PERMISSION)
  end

  def iin_like?(value)
    raw = Search::QueryText.clean(value.to_s)
    return false if raw.blank?

    raw.gsub(/[\s-]/, '').match?(TWELVE_DIGITS_REGEX)
  end

  def masked_placeholder?(value)
    raw = value.to_s.strip
    raw.present? && (raw == MASKED_IIN || raw.match?(MASKED_PLACEHOLDER_REGEX))
  end

  def mask_identifier(value, account_user: Current.account_user)
    can_view_iin?(account_user: account_user) ? value : mask_identifier_unconditional(value)
  end

  def mask_identifier_unconditional(value)
    value.present? && (iin_like?(value) || masked_placeholder?(value)) ? MASKED_IIN : value
  end

  def mask_explicit_iin_value(value, account_user: Current.account_user)
    !can_view_iin?(account_user: account_user) && value.present? ? MASKED_IIN : value
  end

  def mask_attributes_hash(attrs, account_user: Current.account_user)
    return attrs if can_view_iin?(account_user: account_user) || !attrs.is_a?(Hash)

    (EXPLICIT_IIN_KEYS + EXPLICIT_IIN_KEYS.map(&:to_sym)).each_with_object(attrs.dup) { |key, out| mask_hash_entry!(out, key) }
  end

  def mask_hash_entry!(hash, key)
    hash[key] = MASKED_IIN if hash.key?(key) && hash[key].present?
  end

  def strip_masked_iin_entries(attrs)
    return attrs if attrs.blank?

    (EXPLICIT_IIN_KEYS + EXPLICIT_IIN_KEYS.map(&:to_sym)).each_with_object(attrs.dup) do |key, cleaned|
      cleaned.delete(key) if cleaned.key?(key) && masked_placeholder?(cleaned[key])
    end
  end

  def mask_realtime_payload(payload, account_user: Current.account_user, force_mask: false)
    return payload unless realtime_mask_needed?(payload, account_user, force_mask)

    data_parent = realtime_data_parent(payload)
    payload.to_h { |key, val| [key, mask_realtime_node(val, parent_key: key.to_s == 'data' ? data_parent : key.to_s)] }
  end

  def realtime_mask_needed?(payload, account_user, force_mask)
    payload.is_a?(Hash) && (force_mask || !can_view_iin?(account_user: account_user))
  end

  def realtime_data_parent(payload)
    (payload['event'] || payload[:event]).to_s.start_with?('contact.') ? 'contact' : 'data'
  end

  def mask_realtime_node(node, parent_key: nil)
    return node.map { |item| mask_realtime_node(item, parent_key: parent_key) } if node.is_a?(Array)
    return node unless node.is_a?(Hash)

    contact_node = contact_realtime_node?(node, parent_key)
    node.to_h { |key, val| [key, mask_realtime_entry(key.to_s, val, contact_node: contact_node)] }
  end

  def mask_realtime_entry(key_s, val, contact_node:)
    return mask_realtime_node(val, parent_key: key_s) if val.is_a?(Hash) || val.is_a?(Array)
    return (val.present? ? MASKED_IIN : val) if REALTIME_EXPLICIT_IIN_KEYS.include?(key_s.downcase)
    return mask_identifier_unconditional(val) if realtime_identifier_key?(key_s, contact_node)

    val
  end

  def realtime_identifier_key?(key_s, contact_node)
    key_s == 'client_identifier' || (contact_node && key_s == 'identifier')
  end

  def contact_realtime_node?(hash, parent_key)
    CONTACT_REALTIME_PARENTS.include?(parent_key.to_s) || (hash['type'] || hash[:type]).to_s.casecmp('contact').zero?
  end

  def contact_iin_for_export(contact, account_user: Current.account_user)
    raw = raw_contact_iin(contact)
    return '' if raw.blank?

    can_view_iin?(account_user: account_user) ? raw.to_s : MASKED_IIN
  end

  def raw_contact_iin(contact)
    return nil if contact.blank?

    custom = contact.custom_attributes.to_h
    custom['iin'].presence || custom['medelement_iin'].presence ||
      contact.additional_attributes.to_h['iin'].presence ||
      (iin_like?(contact.identifier) ? contact.identifier : nil)
  end

  def iin_search_query?(raw_query)
    text = Search::QueryText.clean(raw_query.to_s)
    text.present? && (text.gsub(/[\s-]/, '').match?(TWELVE_DIGITS_REGEX) || text.match?(EMBEDDED_TWELVE_DIGITS_REGEX))
  end

  def restricted_filter?(payload, account_user: Current.account_user)
    !can_view_iin?(account_user: account_user) && Array(payload).any? { |rule| restricted_filter_rule?(rule) }
  end

  def restricted_filter_rule?(rule)
    return false unless rule.is_a?(Hash) || rule.is_a?(ActionController::Parameters)

    key = (rule['attribute_key'] || rule[:attribute_key]).to_s.strip.downcase
    values = Array(rule['values'] || rule[:values])
    FILTER_IIN_ATTRIBUTE_KEYS.include?(key) || values.any? { |val| iin_search_query?(val) }
  end
end
