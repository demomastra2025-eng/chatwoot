# frozen_string_literal: true

module Filters::CrmDealContextFilter
  private

  def crm_deal_context_filter_query(query_hash, current_index)
    @filter_values["account_id_#{current_index}"] = @account.id

    operator = query_hash[:filter_operator] == 'not_equal_to' ? 'NOT IN' : 'IN'
    "#{filter_config[:table_name]}.id #{operator} " \
      "(#{crm_stage_matching_conversation_ids_sql(current_index)}) #{query_hash[:query_operator]}"
  end

  def crm_stage_matching_deals_sql(current_index)
    account_bind = ":account_id_#{current_index}"
    value_bind = ":value_#{current_index}"

    'SELECT crm_deals.id FROM crm_deals ' \
      "WHERE crm_deals.account_id = #{account_bind} " \
      'AND crm_deals.archived_at IS NULL ' \
      "AND crm_deals.stage_id IN (#{value_bind})"
  end

  def crm_stage_matching_conversation_ids_sql(current_index)
    account_bind = ":account_id_#{current_index}"
    matching_deals = crm_stage_matching_deals_sql(current_index)

    'SELECT crm_stage_conversations.id FROM conversations crm_stage_conversations ' \
      "WHERE crm_stage_conversations.account_id = #{account_bind} AND (" \
      "crm_stage_conversations.id IN (#{crm_stage_direct_conversation_ids_sql(matching_deals)}) OR " \
      "crm_stage_conversations.contact_id IN (#{crm_stage_contact_ids_sql(current_index, matching_deals)}) OR " \
      "crm_stage_conversations.id IN (#{crm_stage_thread_conversation_ids_sql(current_index, matching_deals)})" \
      ')'
  end

  def crm_stage_direct_conversation_ids_sql(matching_deals_sql)
    'SELECT crm_deals.originating_conversation_id FROM crm_deals ' \
      "WHERE crm_deals.id IN (#{matching_deals_sql}) " \
      'AND crm_deals.originating_conversation_id IS NOT NULL'
  end

  def crm_stage_contact_ids_sql(current_index, matching_deals_sql)
    account_bind = ":account_id_#{current_index}"

    'SELECT crm_deal_contacts.contact_id FROM crm_deal_contacts ' \
      "WHERE crm_deal_contacts.account_id = #{account_bind} " \
      "AND crm_deal_contacts.deal_id IN (#{matching_deals_sql})"
  end

  def crm_stage_thread_conversation_ids_sql(current_index, matching_deals_sql)
    account_bind = ":account_id_#{current_index}"

    'SELECT communication_thread_conversations.conversation_id FROM communication_thread_conversations ' \
      "WHERE communication_thread_conversations.account_id = #{account_bind} " \
      'AND communication_thread_conversations.communication_thread_id IN (' \
      'SELECT crm_deals.originating_communication_thread_id FROM crm_deals ' \
      "WHERE crm_deals.id IN (#{matching_deals_sql}) " \
      'AND crm_deals.originating_communication_thread_id IS NOT NULL)'
  end
end
