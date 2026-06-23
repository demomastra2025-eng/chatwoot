# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Crm::DealDialogUnreadCountService do
  let(:account) { create(:account) }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:other_pipeline) { create(:crm_pipeline, account: account) }
  let(:inactive_pipeline) { create(:crm_pipeline, account: account, active: false) }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:other_stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:inactive_stage) { create(:crm_stage, account: account, pipeline: pipeline, active: false) }
  let(:inactive_pipeline_stage) { create(:crm_stage, account: account, pipeline: inactive_pipeline) }

  before do
    account.enable_features!('communication_threads')
  end

  describe '#conversation_pipeline_counts and #conversation_stage_counts' do
    let(:visible_conversation_ids) { account.conversations.where.not(id: excluded_conversation.id).select(:id) }
    let(:conversation_scope) { account.conversations.where(id: visible_conversation_ids) }
    let(:excluded_conversation) { create(:conversation, account: account) }
    let(:service) { described_class.new(account: account, conversation_scope: conversation_scope) }

    it 'groups visible conversations by active CRM pipeline and stage in one pass' do
      direct_conversation = create(:conversation, account: account)
      contact_conversation = create(:conversation, account: account)
      thread_conversation = create(:conversation, account: account)
      duplicate_stage_conversation = create(:conversation, account: account)
      inactive_stage_conversation = create(:conversation, account: account)
      inactive_pipeline_conversation = create(:conversation, account: account)

      create(:crm_deal, account: account, pipeline: pipeline, stage: stage, originating_conversation: direct_conversation)
      create(:crm_deal, account: account, pipeline: pipeline, stage: other_stage, originating_conversation: duplicate_stage_conversation)
      create(:crm_deal, account: account, pipeline: pipeline, stage: other_stage, originating_conversation: duplicate_stage_conversation)
      create(:crm_deal, account: account, pipeline: pipeline, stage: inactive_stage,
                        originating_conversation: inactive_stage_conversation)
      create(:crm_deal, account: account, pipeline: inactive_pipeline, stage: inactive_pipeline_stage,
                        originating_conversation: inactive_pipeline_conversation)
      create(:crm_deal, account: account, pipeline: pipeline, stage: stage, originating_conversation: excluded_conversation)
      create(:crm_deal, account: account, pipeline: other_pipeline,
                        stage: create(:crm_stage, account: account, pipeline: other_pipeline),
                        originating_conversation: direct_conversation)

      contact_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: other_stage)
      create(:crm_deal_contact, account: account, deal: contact_deal, contact: contact_conversation.contact)
      create(:crm_deal, account: account, pipeline: pipeline, stage: other_stage,
                        originating_communication_thread: communication_thread_for(thread_conversation))

      expect(service.conversation_pipeline_counts).to include(
        pipeline.id.to_s => 4,
        other_pipeline.id.to_s => 1
      )
      expect(service.conversation_pipeline_counts).not_to include(inactive_pipeline.id.to_s)
      expect(service.conversation_stage_counts).to include(
        stage.id.to_s => 1,
        other_stage.id.to_s => 3
      )
      expect(service.conversation_stage_counts).not_to include(inactive_stage.id.to_s)
    end

    it 'does not issue one query per active stage' do
      8.times do
        current_stage = create(:crm_stage, account: account, pipeline: pipeline)
        conversation = create(:conversation, account: account)
        create(:crm_deal, account: account, pipeline: pipeline, stage: current_stage, originating_conversation: conversation)
      end

      counter = service

      expect(count_sql_queries { counter.conversation_stage_counts }).to eq(1)
    end
  end

  describe '#communication_thread_pipeline_counts and #communication_thread_stage_counts' do
    let(:communication_thread_scope) { CommunicationThread.where(account_id: account.id).where('communication_threads.unread_count > 0') }
    let(:service) { described_class.new(account: account, communication_thread_scope: communication_thread_scope) }

    it 'groups visible communication threads by active CRM pipeline and stage in one pass' do
      direct_thread_conversation = create(:conversation, account: account)
      contact_thread_conversation = create(:conversation, account: account)
      conversation_thread_conversation = create(:conversation, account: account)
      read_thread_conversation = create(:conversation, account: account)

      [direct_thread_conversation, contact_thread_conversation, conversation_thread_conversation].each do |conversation|
        communication_thread_for(conversation).update!(unread_count: 1)
      end

      create(:crm_deal, account: account, pipeline: pipeline, stage: stage,
                        originating_communication_thread: communication_thread_for(direct_thread_conversation))
      contact_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: other_stage)
      create(:crm_deal_contact, account: account, deal: contact_deal, contact: contact_thread_conversation.contact)
      create(:crm_deal, account: account, pipeline: other_pipeline, stage: create(:crm_stage, account: account, pipeline: other_pipeline),
                        originating_conversation: conversation_thread_conversation)
      create(:crm_deal, account: account, pipeline: pipeline, stage: stage,
                        originating_communication_thread: communication_thread_for(read_thread_conversation))

      expect(service.communication_thread_pipeline_counts).to include(
        pipeline.id.to_s => 2,
        other_pipeline.id.to_s => 1
      )
      expect(service.communication_thread_stage_counts).to include(
        stage.id.to_s => 1,
        other_stage.id.to_s => 1
      )
    end

    it 'does not issue one query per active stage' do
      8.times do
        current_stage = create(:crm_stage, account: account, pipeline: pipeline)
        conversation = create(:conversation, account: account)
        communication_thread_for(conversation).update!(unread_count: 1)
        create(:crm_deal, account: account, pipeline: pipeline, stage: current_stage,
                          originating_communication_thread: communication_thread_for(conversation))
      end

      counter = service

      expect(count_sql_queries { counter.communication_thread_stage_counts }).to eq(1)
    end
  end

  def count_sql_queries(&)
    count = 0
    subscriber = lambda do |*, payload|
      next if payload[:name] == 'SCHEMA' || payload[:cached]

      count += 1
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
    count
  end

  def communication_thread_for(conversation)
    conversation.reload.communication_thread || conversation.refresh_communication_thread!
  end
end
