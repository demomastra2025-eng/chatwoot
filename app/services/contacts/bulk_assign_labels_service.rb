class Contacts::BulkAssignLabelsService
  def initialize(account:, contact_ids:, labels:, remove_labels: [])
    @account = account
    @contact_ids = Array(contact_ids)
    @labels = Array(labels).compact_blank
    @remove_labels = Array(remove_labels).compact_blank
  end

  # Labels belong to the person: they go to the contact and to every conversation of the person, one change per person
  # (Labels::UnifiedAssignmentService).
  def perform
    return { success: true, updated_contact_ids: [] } if @contact_ids.blank? || (@labels.blank? && @remove_labels.blank?)

    contacts = @account.contacts.where(id: @contact_ids)

    contacts.find_each do |contact|
      Labels::UnifiedAssignmentService.new(contact: contact, add: @labels, remove: @remove_labels).perform
    end

    { success: true, updated_contact_ids: contacts.pluck(:id) }
  end
end
