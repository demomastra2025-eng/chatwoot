class Contacts::PhoneMergeService
  def initialize(account:, base_contact:, mergee_contact:)
    @account = account
    @base_contact = base_contact
    @mergee_contact = mergee_contact
  end

  def perform!
    repoint_shared_dependents!
    transfer_mergee_phones!
  end

  private

  attr_reader :account, :base_contact, :mergee_contact

  def repoint_shared_dependents!
    repoint_shared_phone_rows!
    repoint_shared_owner_attributes!
  end

  def repoint_shared_phone_rows!
    ContactPhone.where(account_id: account.id, owner_contact_id: mergee_contact.id)
                .where.not(contact_id: [base_contact.id, mergee_contact.id])
                .update_all(owner_contact_id: base_contact.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def repoint_shared_owner_attributes!
    owner_key = Contacts::SharedPhone::SHARED_OWNER_KEY
    dependent_contacts_for(owner_key).find_each do |dependent|
      attrs = dependent.custom_attributes.to_h.deep_dup
      attrs[owner_key] = base_contact.id
      dependent.update_columns(custom_attributes: attrs, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def dependent_contacts_for(owner_key)
    account.contacts
           .where.not(id: [base_contact.id, mergee_contact.id])
           .where('custom_attributes ->> ? = ?', owner_key, mergee_contact.id.to_s)
  end

  def transfer_mergee_phones!
    mergee_rows = mergee_contact.contact_phones.to_a
    mergee_rows.each { |row| absorb_mergee_row!(row) }
    absorb_unmirrored_mergee_primary!
    ContactPhone.where(account_id: account.id, contact_id: mergee_contact.id).delete_all
    base_contact.association(:contact_phones).reset
  end

  def absorb_mergee_row!(row)
    existing = base_contact.contact_phones.find_by(phone_number: row.phone_number)
    if existing
      row.destroy!
      upgrade_existing_base_row!(existing, row)
    else
      move_row_to_base!(row)
    end
  end

  def upgrade_existing_base_row!(existing, row)
    updates = {}
    if existing.shared? && !row.shared?
      updates[:shared] = false
      updates[:owner_contact_id] = nil
    elsif existing.owner_contact_id == mergee_contact.id
      updates[:owner_contact_id] = nil
    end
    updates[:label] = row.label if existing.label.blank? && row.label.present?
    existing.update_columns(updates.merge(updated_at: Time.current)) if updates.any? # rubocop:disable Rails/SkipsModelValidations
  end

  def move_row_to_base!(row)
    next_owner_id = row.shared? && row.owner_contact_id != base_contact.id ? row.owner_contact_id : nil
    row.update_columns( # rubocop:disable Rails/SkipsModelValidations
      contact_id: base_contact.id,
      primary: false,
      shared: row.shared? && next_owner_id.present?,
      owner_contact_id: next_owner_id,
      updated_at: Time.current
    )
  end

  def absorb_unmirrored_mergee_primary!
    raw_phone = mergee_contact.phone_number.presence
    return if raw_phone.blank? || !raw_phone.match?(ContactPhone::E164_FORMAT)
    return if ContactPhone.exists?(account_id: account.id, contact_id: base_contact.id, phone_number: raw_phone)

    ContactPhone.create!(
      account_id: account.id,
      contact_id: base_contact.id,
      phone_number: raw_phone,
      primary: false,
      shared: false
    )
  end
end
