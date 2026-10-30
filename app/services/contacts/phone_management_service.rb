class Contacts::PhoneManagementService # rubocop:disable Metrics/ClassLength
  class Error < StandardError
    attr_reader :code, :status, :details

    def initialize(code:, message:, status: :unprocessable_content, details: {})
      super(message)
      @code = code
      @status = status
      @details = details
    end
  end

  def initialize(account:, contact:, actor: Current.user)
    @account = account
    @contact = contact
    @actor = actor
    raise ArgumentError, 'Contact must belong to account' unless contact.account_id == account.id
  end

  def add!(raw_phone:, label: nil, link_shared: false)
    normalized = normalize_phone!(raw_phone)
    clean_label = label.to_s.strip.presence

    ApplicationRecord.transaction do
      Contacts::PhoneIdentityLock.acquire!(account_id: account.id)
      contact.reload
      perform_add!(normalized, clean_label, link_shared: link_shared)
    end

    contact.reload
  end

  def set_primary!(phone_id:)
    ApplicationRecord.transaction do
      Contacts::PhoneIdentityLock.acquire!(account_id: account.id)
      row = contact.contact_phones.find(phone_id)
      ensure_owned_row!(row)
      return contact if contact.phone_number == row.phone_number && row.primary?

      contact.preserve_demoted_primary_phone = true
      contact.update!(phone_number: row.phone_number)
    end

    contact.reload
  end

  def remove!(phone_id:)
    released_phone, affected_owner = perform_remove_in_transaction!(phone_id)
    enqueue_released_phone(released_phone) if released_phone.present?
    affected_owner&.dispatch_shared_phone_update_event
    contact.reload
  end

  private

  attr_reader :account, :contact, :actor

  def perform_add!(normalized, clean_label, link_shared:)
    existing = contact.contact_phones.find_by(phone_number: normalized)
    if existing
      return promote_orphaned_shared_row!(existing, normalized, clean_label) if promote_orphaned_shared?(existing, normalized, link_shared)

      existing.update!(label: clean_label) if clean_label.present? && existing.label != clean_label
      return
    end

    if Contacts::SharedPhone.assignable_primary?(account_id: account.id, phone: normalized, contact_id: contact.id)
      assign_owned_phone!(normalized, clean_label)
    else
      assign_or_reject_occupied_phone!(normalized, clean_label, link_shared: link_shared)
    end
  end

  def promote_orphaned_shared?(existing, normalized, link_shared)
    !link_shared &&
      existing.shared? &&
      Contacts::SharedPhone.assignable_primary?(account_id: account.id, phone: normalized, contact_id: contact.id)
  end

  def promote_orphaned_shared_row!(existing, normalized, clean_label)
    label_to_keep = clean_label.presence || existing.label
    existing.destroy!
    assign_owned_phone!(normalized, label_to_keep)
  end

  def ensure_owned_row!(row)
    return unless row.shared?

    raise Error.new(
      code: 'SHARED_PHONE_CANNOT_BE_PRIMARY',
      message: 'Shared family phone cannot be set as primary directly',
      status: :unprocessable_content
    )
  end

  def perform_remove_in_transaction!(phone_id)
    ApplicationRecord.transaction do
      Contacts::PhoneIdentityLock.acquire!(account_id: account.id)
      row = contact.contact_phones.find(phone_id)
      next [remove_primary_row!(row), nil] if row.primary?
      next [nil, remove_shared_row!(row)] if row.shared?

      [remove_secondary_owned_row!(row), nil]
    end
  end

  def enqueue_released_phone(phone)
    Contacts::SharedPhoneReleasedJob.enqueue(account_id: account.id, phone: phone, previous_holder_id: contact.id)
  end

  def normalize_phone!(raw_phone)
    normalized = ::Contacts::PhoneNumberNormalizer.normalize(raw_phone.to_s.strip, default_country: 'KZ') ||
                 ::Contacts::PhoneNumberNormalizer.normalize(raw_phone.to_s.strip)
    return normalized if normalized.present? && normalized.match?(ContactPhone::E164_FORMAT)

    raise Error.new(code: 'INVALID_PHONE_NUMBER', message: I18n.t('errors.contacts.phone_number.invalid'))
  end

  def assign_owned_phone!(normalized, clean_label)
    return assign_first_personal_phone!(normalized, clean_label) if contact.phone_number.blank?

    contact.contact_phones.create!(account_id: account.id, phone_number: normalized, primary: false, shared: false, label: clean_label)
    contact.dispatch_shared_phone_update_event
  end

  def assign_first_personal_phone!(normalized, clean_label)
    existing_shared = contact.contact_phones.where(shared: true).includes(:owner_contact).to_a
    attrs = preserve_shared_phones_on_first_personal_phone(existing_shared)
    update_params = { phone_number: normalized }
    update_params[:custom_attributes] = attrs if attrs.present?
    contact.update!(update_params)
    apply_primary_label_and_notify!(normalized, clean_label, existing_shared)
  end

  def apply_primary_label_and_notify!(normalized, clean_label, existing_shared)
    contact.contact_phones.find_by(phone_number: normalized)&.update!(label: clean_label) if clean_label.present?
    existing_shared.filter_map(&:owner_contact).uniq(&:id).each(&:dispatch_shared_phone_update_event)
  end

  def preserve_shared_phones_on_first_personal_phone(existing_shared)
    return if existing_shared.empty?

    attrs = contact.custom_attributes.to_h.deep_dup
    secondary_key = Contacts::SharedPhone::SECONDARY_PHONES_KEY
    attrs[secondary_key] = (Array(attrs[secondary_key]) + existing_shared.map(&:phone_number)).compact_blank.uniq
    attrs
  end

  def assign_or_reject_occupied_phone!(normalized, clean_label, link_shared:)
    share_info = Contacts::SharedPhone.existing_share_for(account_id: account.id, phone: normalized, excluding: [contact.id])
    owner = account.contacts.find_by(id: share_info&.dig(:owner_id))
    raise occupied_phone_error(normalized, owner) unless link_shared && owner.present?

    link_shared_phone!(normalized, clean_label, owner: owner, share_info: share_info)
  end

  def occupied_phone_error(normalized, owner)
    owner_payload = owner && { id: owner.id, name: owner.display_full_name, thumbnail: owner.resolved_avatar_url }
    Error.new(
      code: 'PHONE_OWNED_BY_OTHER_CONTACT',
      message: 'Phone number already belongs to another contact',
      status: :conflict,
      details: { phone_number: normalized, can_link_shared: owner.present?, owner_contact: owner_payload }
    )
  end

  def link_shared_phone!(normalized, clean_label, owner:, share_info:)
    contact.contact_phones.create!(
      account_id: account.id, phone_number: normalized, primary: false, shared: true, owner_contact_id: owner.id, label: clean_label
    )
    contact.update!(custom_attributes: shared_custom_attributes(normalized, owner, share_info))
    owner.dispatch_shared_phone_update_event
  end

  def shared_custom_attributes(normalized, owner, share_info)
    attrs = contact.custom_attributes.to_h.deep_dup
    if contact.phone_number.blank?
      via = share_info[:via] || Contacts::SharedPhone::VIA_OWNER_PRIMARY
      Contacts::SharedPhone.record_share!(attrs, phone: normalized, owner_id: owner.id, via: via, conversation_id: share_info[:conversation_id])
    else
      secondary_key = Contacts::SharedPhone::SECONDARY_PHONES_KEY
      attrs[secondary_key] = (Array(attrs[secondary_key]) + [normalized]).compact_blank.uniq
    end
    attrs
  end

  def remove_primary_row!(row)
    next_owned = contact.contact_phones.where(shared: false).where.not(id: row.id).order(:id).first
    row.destroy!
    contact.update!(phone_number: next_owned&.phone_number)
    nil
  end

  def remove_shared_row!(row)
    owner = row.owner_contact
    removed_phone = row.phone_number
    row.destroy!

    attrs = contact.custom_attributes.to_h.deep_dup
    attrs[Contacts::SharedPhone::SECONDARY_PHONES_KEY] = Array(attrs[Contacts::SharedPhone::SECONDARY_PHONES_KEY]) - [removed_phone]
    reconcile_removed_share_attributes!(attrs, removed_phone)
    contact.update!(custom_attributes: attrs)
    owner
  end

  def reconcile_removed_share_attributes!(attrs, removed_phone)
    return unless removed_active_share?(attrs, removed_phone)

    fallback = contact.contact_phones.where(shared: true).order(:id).first if contact.phone_number.blank?
    fallback&.owner_contact_id.present? ? apply_fallback_share!(attrs, fallback) : Contacts::SharedPhone.clear_share!(attrs)
  end

  def removed_active_share?(attrs, removed_phone)
    Contacts::SharedPhone.share_of(contact)&.phone == removed_phone || attrs[Contacts::SharedPhone::SHARED_PHONE_KEY] == removed_phone
  end

  def apply_fallback_share!(attrs, fallback)
    secondary_key = Contacts::SharedPhone::SECONDARY_PHONES_KEY
    attrs[secondary_key] = (Array(attrs[secondary_key]) + [fallback.phone_number]).compact_blank.uniq
    Contacts::SharedPhone.record_share!(
      attrs, phone: fallback.phone_number, owner_id: fallback.owner_contact_id, via: Contacts::SharedPhone::VIA_OWNER_PRIMARY
    )
  end

  def remove_secondary_owned_row!(row)
    removed_phone = row.phone_number
    row.destroy!

    attrs = contact.custom_attributes.to_h.deep_dup
    if Array(attrs[Contacts::SharedPhone::SECONDARY_PHONES_KEY]).include?(removed_phone)
      attrs[Contacts::SharedPhone::SECONDARY_PHONES_KEY] = Array(attrs[Contacts::SharedPhone::SECONDARY_PHONES_KEY]) - [removed_phone]
      contact.update!(custom_attributes: attrs)
    else
      contact.dispatch_shared_phone_update_event
    end
    removed_phone
  end
end
