class Campaigns::AudienceResolver
  pattr_initialize [:account!, :audience, { audience_import: nil }]

  def contacts
    return imported_contacts if audience_import.present?
    return account.contacts.none if label_titles.blank?

    account.contacts
           .where(id: direct_contact_ids)
           .or(account.contacts.where(id: tagged_conversation_contact_ids))
           .distinct
  end

  def label_titles
    @label_titles ||= account.labels.where(id: label_ids).pluck(:title)
  end

  private

  def imported_contacts
    return account.contacts.none unless audience_import.account_id == account.id

    account.contacts.where(id: audience_import.recipients.select(:contact_id)).distinct
  end

  def label_ids
    @label_ids ||= Array.wrap(audience).filter_map do |entry|
      entry = entry.to_h if entry.respond_to?(:to_h)
      entry = entry.with_indifferent_access
      entry[:id] if entry[:type] == 'Label'
    end
  end

  def direct_contacts
    account.contacts.tagged_with(label_titles, any: true)
  end

  def direct_contact_ids
    direct_contacts.unscope(:select, :order).reselect(:id)
  end

  def tagged_conversation_contact_ids
    account.conversations
           .tagged_with(label_titles, any: true)
           .unscope(:select, :order)
           .where.not(contact_id: nil)
           .reselect(:contact_id)
  end
end
