# frozen_string_literal: true

class Crm::DealDialogScopeBuilder
  attr_reader :account, :pipeline_id, :stage_id

  def initialize(account:, pipeline_id: nil, stage_id: nil)
    @account = account
    @pipeline_id = normalize_id(pipeline_id)
    @stage_id = normalize_id(stage_id)
  end

  def active?
    pipeline_id.present? || stage_id.present?
  end

  def filter_conversations(scope)
    return scope unless active?

    scope.where(id: conversation_ids)
  end

  def filter_communication_threads(scope)
    return scope unless active?

    scope.where(id: communication_thread_ids)
  end

  def conversation_ids
    return account.conversations.none.select(:id) unless active?

    account.conversations.where(id: direct_conversation_ids)
           .or(account.conversations.where(id: contact_conversation_ids))
           .or(account.conversations.where(id: thread_conversation_ids))
           .select(:id)
  end

  def communication_thread_ids
    return CommunicationThread.none.select(:id) unless active?

    account_threads.where(id: direct_thread_ids)
                   .or(account_threads.where(id: contact_thread_ids))
                   .or(account_threads.where(id: conversation_thread_ids))
                   .select(:id)
  end

  private

  def normalize_id(value)
    value.presence
  end

  def deal_scope
    scope = account.crm_deals.kept
    scope = scope.where(pipeline_id: pipeline_id) if pipeline_id.present?
    scope = scope.where(stage_id: stage_id) if stage_id.present?
    scope
  end

  def direct_conversation_ids
    deal_scope.where.not(originating_conversation_id: nil).select(:originating_conversation_id)
  end

  def direct_thread_ids
    deal_scope.where.not(originating_communication_thread_id: nil).select(:originating_communication_thread_id)
  end

  def deal_contact_ids
    Crm::DealContact.where(account_id: account.id, deal_id: deal_scope.select(:id)).select(:contact_id)
  end

  def contact_conversation_ids
    account.conversations.where(contact_id: deal_contact_ids).select(:id)
  end

  def contact_thread_ids
    account_threads.where(contact_id: deal_contact_ids).select(:id)
  end

  def thread_conversation_ids
    CommunicationThreadConversation.where(
      account_id: account.id,
      communication_thread_id: direct_thread_ids
    ).select(:conversation_id)
  end

  def conversation_thread_ids
    CommunicationThreadConversation.where(
      account_id: account.id,
      conversation_id: direct_conversation_ids
    ).select(:communication_thread_id)
  end

  def account_threads
    CommunicationThread.where(account_id: account.id)
  end
end
