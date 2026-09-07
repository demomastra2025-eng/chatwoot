module Crm::Deals::UpsertContacts
  private

  def sync_contacts!(contacts:, primary_contact:)
    existing_links = deal.deal_contacts.index_by(&:contact_id)
    removed = remove_stale_contact_links!(contacts)
    updated = upsert_contact_links!(contacts, primary_contact, existing_links)
    removed || updated
  end

  def remove_stale_contact_links!(contacts)
    removed = false
    deal.deal_contacts.where.not(contact_id: contacts.map(&:id)).find_each do |deal_contact|
      deal_contact.destroy!
      removed = true
    end
    removed
  end

  def upsert_contact_links!(contacts, primary_contact, existing_links)
    contacts.filter_map do |contact|
      deal_contact = existing_links[contact.id] || deal.deal_contacts.new(account: account, contact: contact)
      next unless contact_link_changed?(deal_contact, contact, primary_contact)

      deal_contact.update!(account: account, contact: contact, primary: contact.id == primary_contact&.id)
      true
    end.any?
  end

  def contact_link_changed?(deal_contact, contact, primary_contact)
    deal_contact.new_record? || deal_contact.primary != (contact.id == primary_contact&.id)
  end

  def sync_owner_to_primary_contact!(primary_contact)
    return if primary_contact.blank?
    return if primary_contact.owner_id == deal.owner_id

    primary_contact.update!(owner_id: deal.owner_id)
  end

  def sync_incomplete_task_teams!
    tasks = incomplete_tasks_for_team_sync
    tasks.find_each do |task|
      ::Crm::Tasks::UpsertService.new(
        account: account,
        actor: actor,
        params: { lock_version: task.lock_version },
        task: task
      ).perform
    end
  end

  def incomplete_tasks_for_team_sync
    tasks = deal.tasks
                .kept
                .joins(:status)
                .where(crm_task_statuses: { category: %w[open in_progress] })
    return tasks.where.not(team_id: deal.team_id).or(tasks.where(team_id: nil)) if deal.team_id.present?

    tasks.where.not(team_id: nil)
  end
end
