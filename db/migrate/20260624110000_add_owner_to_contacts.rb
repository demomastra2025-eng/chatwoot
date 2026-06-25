class AddOwnerToContacts < ActiveRecord::Migration[7.1]
  def change
    add_reference :contacts, :owner, foreign_key: { to_table: :users }, index: true

    reversible do |dir|
      dir.up do
        backfill_owner_from_conversations
        backfill_owner_from_primary_deals
      end
    end
  end

  private

  def backfill_owner_from_conversations
    execute <<~SQL.squish
      UPDATE contacts
      SET owner_id = latest_conversations.assignee_id
      FROM (
        SELECT DISTINCT ON (contact_id, account_id)
          contact_id,
          account_id,
          assignee_id
        FROM conversations
        WHERE assignee_id IS NOT NULL
        ORDER BY contact_id, account_id, last_activity_at DESC NULLS LAST, id DESC
      ) latest_conversations
      WHERE contacts.id = latest_conversations.contact_id
        AND contacts.account_id = latest_conversations.account_id
        AND contacts.owner_id IS NULL
    SQL
  end

  def backfill_owner_from_primary_deals
    execute <<~SQL.squish
      UPDATE contacts
      SET owner_id = primary_deals.owner_id
      FROM (
        SELECT DISTINCT ON (crm_deal_contacts.contact_id, crm_deal_contacts.account_id)
          crm_deal_contacts.contact_id,
          crm_deal_contacts.account_id,
          crm_deals.owner_id
        FROM crm_deal_contacts
        INNER JOIN crm_deals ON crm_deals.id = crm_deal_contacts.deal_id
        WHERE crm_deals.owner_id IS NOT NULL
          AND crm_deal_contacts.primary = TRUE
        ORDER BY crm_deal_contacts.contact_id, crm_deal_contacts.account_id, crm_deals.updated_at DESC, crm_deals.id DESC
      ) primary_deals
      WHERE contacts.id = primary_deals.contact_id
        AND contacts.account_id = primary_deals.account_id
        AND contacts.owner_id IS NULL
    SQL
  end
end
