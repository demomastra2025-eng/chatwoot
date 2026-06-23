# frozen_string_literal: true

module Crm::DealDialogContextSql
  private

  def conversation_context_rows_sql
    [
      direct_conversation_context_sql,
      contact_conversation_context_sql,
      thread_conversation_context_sql
    ].join(' UNION ALL ')
  end

  def communication_thread_context_rows_sql
    [
      direct_thread_context_sql,
      contact_thread_context_sql,
      conversation_thread_context_sql
    ].join(' UNION ALL ')
  end

  def direct_conversation_context_sql
    <<~SQL.squish
      SELECT crm_deals.originating_conversation_id AS conversation_id,
             crm_deals.pipeline_id,
             crm_deals.stage_id
      FROM crm_deals
      WHERE crm_deals.account_id = :account_id
        AND crm_deals.archived_at IS NULL
        AND crm_deals.originating_conversation_id IS NOT NULL
    SQL
  end

  def contact_conversation_context_sql
    <<~SQL.squish
      SELECT conversations.id AS conversation_id,
             crm_deals.pipeline_id,
             crm_deals.stage_id
      FROM crm_deals
      INNER JOIN crm_deal_contacts
        ON crm_deal_contacts.deal_id = crm_deals.id
       AND crm_deal_contacts.account_id = :account_id
      INNER JOIN conversations
        ON conversations.contact_id = crm_deal_contacts.contact_id
       AND conversations.account_id = :account_id
      WHERE crm_deals.account_id = :account_id
        AND crm_deals.archived_at IS NULL
    SQL
  end

  def thread_conversation_context_sql
    <<~SQL.squish
      SELECT communication_thread_conversations.conversation_id AS conversation_id,
             crm_deals.pipeline_id,
             crm_deals.stage_id
      FROM crm_deals
      INNER JOIN communication_thread_conversations
        ON communication_thread_conversations.communication_thread_id = crm_deals.originating_communication_thread_id
       AND communication_thread_conversations.account_id = :account_id
      WHERE crm_deals.account_id = :account_id
        AND crm_deals.archived_at IS NULL
        AND crm_deals.originating_communication_thread_id IS NOT NULL
    SQL
  end

  def direct_thread_context_sql
    <<~SQL.squish
      SELECT crm_deals.originating_communication_thread_id AS communication_thread_id,
             crm_deals.pipeline_id,
             crm_deals.stage_id
      FROM crm_deals
      WHERE crm_deals.account_id = :account_id
        AND crm_deals.archived_at IS NULL
        AND crm_deals.originating_communication_thread_id IS NOT NULL
    SQL
  end

  def contact_thread_context_sql
    <<~SQL.squish
      SELECT communication_threads.id AS communication_thread_id,
             crm_deals.pipeline_id,
             crm_deals.stage_id
      FROM crm_deals
      INNER JOIN crm_deal_contacts
        ON crm_deal_contacts.deal_id = crm_deals.id
       AND crm_deal_contacts.account_id = :account_id
      INNER JOIN communication_threads
        ON communication_threads.contact_id = crm_deal_contacts.contact_id
       AND communication_threads.account_id = :account_id
      WHERE crm_deals.account_id = :account_id
        AND crm_deals.archived_at IS NULL
    SQL
  end

  def conversation_thread_context_sql
    <<~SQL.squish
      SELECT communication_thread_conversations.communication_thread_id AS communication_thread_id,
             crm_deals.pipeline_id,
             crm_deals.stage_id
      FROM crm_deals
      INNER JOIN communication_thread_conversations
        ON communication_thread_conversations.conversation_id = crm_deals.originating_conversation_id
       AND communication_thread_conversations.account_id = :account_id
      WHERE crm_deals.account_id = :account_id
        AND crm_deals.archived_at IS NULL
        AND crm_deals.originating_conversation_id IS NOT NULL
    SQL
  end
end
