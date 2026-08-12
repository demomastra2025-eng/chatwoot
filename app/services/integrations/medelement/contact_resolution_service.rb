class Integrations::Medelement::ContactResolutionService
  class UnsafeDeletionError < StandardError; end
  class UnsupportedConflictError < StandardError; end

  def initialize(conflict:, user:)
    @conflict = conflict
    @user = user
  end

  def merge_contacts!(base_contact_id:, mergee_contact_id:)
    ensure_contact_conflict!
    base_contact = nil

    conflict.with_lock do
      ensure_open_conflict!
      base_contact, mergee_contact = locked_contacts!(base_contact_id, mergee_contact_id)
      ensure_merge_direction!(base_contact, mergee_contact)

      ContactMergeAction.new(
        account: conflict.account,
        base_contact: base_contact,
        mergee_contact: mergee_contact
      ).perform
      resolve!("Contacts merged into ##{base_contact.id}")
    end
    base_contact
  end

  def delete!(contact_id:)
    ensure_contact_conflict!

    conflict.with_lock do
      ensure_open_conflict!
      contact = conflict.account.contacts.lock.find(contact_id)
      ensure_conflict_contacts!(contact)
      raise UnsafeDeletionError, 'Contact has related data and cannot be deleted' unless self.class.safe_to_delete?(contact)

      contact.destroy!
      resolve!("Empty contact ##{contact.id} deleted")
    end
  end

  def keep_separate!(note:)
    ensure_contact_conflict!
    ensure_open_conflict!
    normalized_note = note.to_s.strip
    raise ArgumentError, 'Resolution note is required' if normalized_note.blank?

    conflict.ignore!(user: user, note: normalized_note)
  end

  def self.safe_to_delete?(contact)
    Contacts::ReferenceMergeService.safe_to_delete?(contact)
  end

  private

  attr_reader :conflict, :user

  def ensure_contact_conflict!
    return if conflict.entity_type == 'contact'

    raise UnsupportedConflictError, 'This conflict cannot be resolved with contact actions'
  end

  def ensure_open_conflict!
    return if conflict.open?

    raise UnsupportedConflictError, 'Only open conflicts can be resolved'
  end

  def scoped_contact!(contact_id)
    conflict.account.contacts.find(contact_id)
  end

  def locked_contacts!(*contact_ids)
    contacts = conflict.account.contacts.where(id: contact_ids).order(:id).lock.index_by(&:id)
    contact_ids.map { |contact_id| contacts.fetch(contact_id.to_i) { raise ActiveRecord::RecordNotFound } }
  end

  def ensure_merge_direction!(base_contact, mergee_contact)
    expected_base_id = conflict.details['contact_id'].to_i
    expected_mergee_id = conflict.details['conflicting_contact_id'].to_i
    return if base_contact.id == expected_base_id && mergee_contact.id == expected_mergee_id

    raise ActiveRecord::RecordNotFound
  end

  def ensure_conflict_contacts!(*contacts)
    allowed_ids = [
      conflict.details['contact_id'],
      conflict.details['conflicting_contact_id']
    ].compact.map(&:to_i).uniq
    return if contacts.all? { |contact| contact.id.in?(allowed_ids) }

    raise ActiveRecord::RecordNotFound
  end

  def resolve!(note)
    conflict.update!(
      status: 'resolved',
      resolved_by: user,
      resolved_at: Time.current,
      resolution_note: note
    )
  end
end
