# retain_original_contact_name: false / true
# In case of setUser we want to update the name of the identified contact,
# which is the default behaviour
#
# But, In case of contact merge during prechat form contact update.
# We don't want to update the name of the identified original contact.

#
# hmac_verified: true only on the widget setUser path after the identifier HMAC was verified. A patient card is never
# merged with a visitor from identify unless that verified identifier is the card's own identifier; values the visitor
# supplied about itself (custom attributes, email, phone) never prove a patient identity.

class ContactIdentifyAction
  include UrlHelper
  pattr_initialize [:contact!, :params!, { retain_original_contact_name: false, discard_invalid_attrs: false, hmac_verified: false }]

  def perform
    @attributes_to_update = [:identifier, :name, :email, :phone_number]

    ActiveRecord::Base.transaction do
      merge_if_existing_identified_contact
      merge_if_existing_email_contact
      merge_if_existing_phone_number_contact
      skip_reserved_phone_number
      update_contact
    end
    @contact
  end

  private

  def account
    @account ||= @contact.account
  end

  def merge_if_existing_identified_contact
    return unless merge_contacts?(existing_identified_contact, :identifier)

    process_contact_merge(existing_identified_contact, :identifier)
  end

  def merge_if_existing_email_contact
    return unless merge_contacts?(existing_email_contact, :email)

    process_contact_merge(existing_email_contact, :email)
  end

  def merge_if_existing_phone_number_contact
    return unless merge_contacts?(existing_phone_number_contact, :phone_number)
    return unless mergable_phone_contact?
    return if unverified_family_number?

    process_contact_merge(existing_phone_number_contact, :phone_number)
  end

  # A visitor that types a family number (some card's recorded shared доп. номер) proves nothing about it: it is never
  # merged into the contact holding the number, whose chats carry the card's notifications, and it does not take the
  # number either (skip_reserved_phone_number).
  def unverified_family_number?
    return false if hmac_verified

    Contacts::ServerOwnedAttributes.family_number?(account_id: account.id, phone: params[:phone_number])
  end

  def process_contact_merge(mergee_contact, key)
    @contact = merge_contact(mergee_contact, @contact)
    @attributes_to_update.delete(:name) if retain_original_contact_name
  rescue Contacts::ReferenceMergeService::UnsafeMergeError
    # The existing contact refuses the merge (a separate patient card, an in-flight provider write): keep the
    # visitor separate and leave the colliding unique value with the existing contact.
    @attributes_to_update.delete(key)
  end

  def existing_identified_contact
    return if params[:identifier].blank?

    @existing_identified_contact ||= account.contacts.find_by(identifier: params[:identifier])
  end

  def existing_email_contact
    return if params[:email].blank?

    @existing_email_contact ||= account.contacts.from_email(params[:email])
  end

  def existing_phone_number_contact
    return if params[:phone_number].blank?

    @existing_phone_number_contact ||= account.contacts.find_by(phone_number: params[:phone_number])
  end

  def merge_contacts?(existing_contact, key)
    return if existing_contact.blank?

    return true if params[:identifier].blank?

    # we want to prevent merging contacts with different identifiers
    if existing_contact.identifier.present? && existing_contact.identifier != params[:identifier]
      # we will remove attribute from update list
      @attributes_to_update.delete(key)
      return false
    end

    true
  end

  # case: contact 1: email: 1@test.com, phone: 123456789
  # params: email: 2@test.com, phone: 123456789
  # we don't want to overwrite 1@test.com since email parameter takes higer priority
  def mergable_phone_contact?
    return true if params[:email].blank?

    if existing_phone_number_contact.email.present? && existing_phone_number_contact.email != params[:email]
      @attributes_to_update.delete(:phone_number)
      return false
    end
    true
  end

  def update_contact
    @contact.attributes = params.slice(*@attributes_to_update).reject do |_k, v|
      v.blank?
    end.merge({ custom_attributes: custom_attributes, additional_attributes: additional_attributes })
    # blank identifier or email will throw unique index error
    # TODO: replace reject { |_k, v| v.blank? } with compact_blank when rails is upgraded
    @contact.discard_invalid_attrs if discard_invalid_attrs
    @contact.save! if @contact.changed?
    enqueue_avatar_job
  end

  def enqueue_avatar_job
    return unless params[:avatar_url].present? && !@contact.avatar.attached?
    return unless url_valid?(params[:avatar_url])

    Avatar::AvatarFromUrlJob.perform_later(@contact, params[:avatar_url])
  end

  def merge_contact(base_contact, merge_contact)
    return base_contact if base_contact.id == merge_contact.id

    ensure_patient_card_merge_verified!(base_contact, merge_contact)
    # Savepoint: a refused merge rolls back its partial reassignment without aborting the identify transaction.
    ActiveRecord::Base.transaction(requires_new: true) do
      ContactMergeAction.new(
        account: account,
        base_contact: base_contact,
        mergee_contact: merge_contact,
        verified_identifier: (params[:identifier].presence if hmac_verified)
      ).perform
    end
  end

  def ensure_patient_card_merge_verified!(base_contact, merge_contact)
    return unless Contacts::SharedPhone.card?(base_contact) || Contacts::SharedPhone.card?(merge_contact)
    return if hmac_verified && params[:identifier].present? && base_contact.identifier == params[:identifier].to_s

    raise Contacts::ReferenceMergeService::UnsafeMergeError, 'A patient card is merged from identify only with its verified identifier'
  end

  def skip_reserved_phone_number
    return unless Contacts::ServerOwnedAttributes.reserved_for_other?(account_id: account.id, phone: params[:phone_number],
                                                                      contact_id: @contact.id)

    @attributes_to_update.delete(:phone_number)
  end

  def custom_attributes
    incoming = Contacts::ServerOwnedAttributes.strip(params[:custom_attributes])
    return @contact.custom_attributes if incoming.blank?

    (@contact.custom_attributes || {}).deep_merge(incoming)
  end

  def additional_attributes
    return @contact.additional_attributes if params[:additional_attributes].blank?

    (@contact.additional_attributes || {}).deep_merge(params[:additional_attributes].stringify_keys)
  end
end
