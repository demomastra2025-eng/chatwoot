# frozen_string_literal: true

class Crm::DealDialogStageContextBuilder
  attr_reader :account

  def initialize(account:)
    @account = account
  end

  def for_conversations(conversations)
    records = Array(conversations)
    return {} if records.blank? || crm_deals_disabled?

    contexts = context_hash
    add_direct_conversation_deals(contexts, records)
    add_contact_deals_for_conversations(contexts, records)
    add_thread_deals_for_conversations(contexts, records)
    contexts_to_payloads(contexts)
  end

  def for_communication_threads(communication_threads)
    records = Array(communication_threads)
    return {} if records.blank? || crm_deals_disabled?

    contexts = context_hash
    add_direct_thread_deals(contexts, records)
    add_contact_deals_for_threads(contexts, records)
    add_conversation_deals_for_threads(contexts, records)
    contexts_to_payloads(contexts)
  end

  private

  def context_hash
    Hash.new { |hash, key| hash[key] = {} }
  end

  def crm_deals_disabled?
    !account.feature_enabled?('crm_deals')
  end

  def deal_scope
    account.crm_deals.kept.includes(:stage, :pipeline)
  end

  def deal_id_scope
    account.crm_deals.kept.select(:id)
  end

  def add_direct_conversation_deals(contexts, conversations)
    conversation_ids = conversations.map(&:id)
    deal_scope.where(originating_conversation_id: conversation_ids).find_each do |deal|
      add_stage_context(contexts, deal.originating_conversation_id, deal)
    end
  end

  def add_contact_deals_for_conversations(contexts, conversations)
    conversation_ids_by_contact_id = records_by_contact_id(conversations)
    add_contact_deals(contexts, conversation_ids_by_contact_id)
  end

  def add_thread_deals_for_conversations(contexts, conversations)
    conversation_ids_by_thread_id = conversation_thread_map(conversations.map(&:id))
    return if conversation_ids_by_thread_id.blank?

    deal_scope.where(originating_communication_thread_id: conversation_ids_by_thread_id.keys).find_each do |deal|
      conversation_ids_by_thread_id[deal.originating_communication_thread_id].each do |conversation_id|
        add_stage_context(contexts, conversation_id, deal)
      end
    end
  end

  def add_direct_thread_deals(contexts, communication_threads)
    thread_ids = communication_threads.map(&:id)
    deal_scope.where(originating_communication_thread_id: thread_ids).find_each do |deal|
      add_stage_context(contexts, deal.originating_communication_thread_id, deal)
    end
  end

  def add_contact_deals_for_threads(contexts, communication_threads)
    thread_ids_by_contact_id = records_by_contact_id(communication_threads)
    add_contact_deals(contexts, thread_ids_by_contact_id)
  end

  def add_conversation_deals_for_threads(contexts, communication_threads)
    thread_ids = communication_threads.map(&:id)
    thread_ids_by_conversation_id = thread_conversation_map(thread_ids)
    return if thread_ids_by_conversation_id.blank?

    deal_scope.where(originating_conversation_id: thread_ids_by_conversation_id.keys).find_each do |deal|
      thread_ids_by_conversation_id[deal.originating_conversation_id].each do |thread_id|
        add_stage_context(contexts, thread_id, deal)
      end
    end
  end

  def add_contact_deals(contexts, record_ids_by_contact_id)
    return if record_ids_by_contact_id.blank?

    Crm::DealContact
      .where(account_id: account.id, contact_id: record_ids_by_contact_id.keys, deal_id: deal_id_scope)
      .includes(deal: [:stage, :pipeline])
      .find_each do |deal_contact|
        record_ids_by_contact_id[deal_contact.contact_id].each do |record_id|
          add_stage_context(contexts, record_id, deal_contact.deal)
        end
      end
  end

  def add_stage_context(contexts, record_id, deal)
    stage = deal&.stage
    return if record_id.blank? || stage.blank?

    contexts[record_id][stage.id] ||= {
      stage: stage,
      pipeline: deal.pipeline
    }
  end

  def contexts_to_payloads(contexts)
    contexts.transform_values do |stage_contexts|
      stage_contexts.values
                    .sort_by { |context| stage_sort_key(context) }
                    .map { |context| stage_payload(context[:stage], context[:pipeline]) }
    end
  end

  def stage_payload(stage, pipeline)
    resolved_pipeline = pipeline || stage.pipeline

    {
      id: stage.id,
      pipeline_id: stage.pipeline_id,
      pipeline_name: resolved_pipeline&.name,
      name: stage.name,
      color: stage.color
    }
  end

  def stage_sort_key(context)
    pipeline = context[:pipeline]
    stage = context[:stage]

    [
      pipeline&.position || 0,
      pipeline&.id || stage.pipeline_id,
      stage.position,
      stage.id
    ]
  end

  def records_by_contact_id(records)
    records.each_with_object({}) do |record, result|
      next if record.contact_id.blank?

      result[record.contact_id] ||= []
      result[record.contact_id] << record.id
    end
  end

  def conversation_thread_map(conversation_ids)
    CommunicationThreadConversation
      .where(account_id: account.id, conversation_id: conversation_ids)
      .pluck(:communication_thread_id, :conversation_id)
      .each_with_object({}) do |(thread_id, conversation_id), result|
        result[thread_id] ||= []
        result[thread_id] << conversation_id
      end
  end

  def thread_conversation_map(thread_ids)
    CommunicationThreadConversation
      .where(account_id: account.id, communication_thread_id: thread_ids)
      .pluck(:communication_thread_id, :conversation_id)
      .each_with_object({}) do |(thread_id, conversation_id), result|
        result[conversation_id] ||= []
        result[conversation_id] << thread_id
      end
  end
end
