module Contacts::PhoneLookup
  module_function

  def candidate_phones(raw_phone, default_country: nil)
    raw = raw_phone.to_s.strip
    return [] if raw.blank?

    candidates = [::Contacts::PhoneNumberNormalizer.normalize(raw)]
    candidates << ::Contacts::PhoneNumberNormalizer.normalize(raw, default_country: default_country) if default_country.present?
    candidates << raw
    candidates.compact_blank.uniq
  end

  def find_owner_contact(account, raw_phone, default_country: nil)
    return if account.blank? || raw_phone.blank?

    candidates = candidate_phones(raw_phone, default_country: default_country)
    return if candidates.empty?

    direct = account.contacts.where(phone_number: candidates).order(:id).first
    return direct if direct

    ContactPhone.includes(:contact)
                .where(account_id: account.id, phone_number: candidates, primary: false, shared: false)
                .order(:id)
                .first&.contact
  end

  def owned_by_other_contact?(account, raw_phone, excluding_contact_id:, default_country: nil)
    return false if account.blank? || raw_phone.blank?

    candidates = candidate_phones(raw_phone, default_country: default_country)
    return false if candidates.empty?

    excluded = Array(excluding_contact_id).compact
    direct_scope = account.contacts.where(phone_number: candidates)
    direct_scope = direct_scope.where.not(id: excluded) if excluded.any?
    return true if direct_scope.exists?

    cp_scope = ContactPhone.where(account_id: account.id, phone_number: candidates, primary: false, shared: false)
    cp_scope = cp_scope.where.not(contact_id: excluded) if excluded.any?
    cp_scope.exists?
  end

  def matching_contact_ids(account, raw_phone, default_country: 'KZ')
    return [] if account.blank? || raw_phone.blank?

    candidates = candidate_phones(raw_phone, default_country: default_country)
    return [] if candidates.empty?

    (
      account.contacts.where(phone_number: candidates).pluck(:id) +
      ContactPhone.where(account_id: account.id, phone_number: candidates).pluck(:contact_id)
    ).uniq
  end
end
