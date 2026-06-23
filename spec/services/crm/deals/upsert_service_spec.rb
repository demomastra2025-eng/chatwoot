require 'rails_helper'

RSpec.describe Crm::Deals::UpsertService do
  let(:account) { create(:account) }
  let(:pipeline) { create(:crm_pipeline, account: account, default: true) }

  it 'creates deals in the configured default stage for the selected pipeline' do
    first_open_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      position: 1,
      color: '#123456',
      default: true
    )
    default_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      position: 5,
      color: '#654321',
      default: true
    )

    deal = described_class.new(
      account: account,
      params: { title: 'Default-stage deal', pipeline_id: pipeline.id }
    ).perform

    expect(deal.stage).to eq(default_stage)
    expect(first_open_stage.reload).not_to be_default
  end

  it 'falls back to the first active open stage when no explicit default exists' do
    won_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      position: 1,
      outcome: 'won',
      color: '#123456'
    )
    first_open_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      position: 2,
      color: '#654321'
    )
    later_open_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      position: 3,
      color: '#111111'
    )
    pipeline.stages.each { |stage| stage.update!(default: false) }

    deal = described_class.new(
      account: account,
      params: { title: 'Fallback-stage deal', pipeline_id: pipeline.id }
    ).perform

    expect(deal.stage).to eq(first_open_stage)
    expect(deal.stage).not_to eq(won_stage)
    expect(deal.stage).not_to eq(later_open_stage)
  end

  it 'defaults a new conversation-sourced deal owner to the conversation assignee when owner_id is omitted' do
    create(:crm_stage, account: account, pipeline: pipeline, default: true)
    assignee = create(:user, account: account, role: :agent)
    actor = create(:user, account: account, role: :agent)
    conversation = create(:conversation, account: account, assignee: assignee)

    deal = described_class.new(
      account: account,
      actor: actor,
      params: {
        title: 'Conversation deal',
        pipeline_id: pipeline.id,
        originating_conversation_id: conversation.id
      }
    ).perform

    expect(deal.owner).to eq(assignee)
  end

  it 'defaults a new thread-sourced deal owner to the communication thread assignee when owner_id is omitted' do
    create(:crm_stage, account: account, pipeline: pipeline, default: true)
    thread_assignee = create(:user, account: account, role: :agent)
    actor = create(:user, account: account, role: :agent)
    communication_thread = create(:communication_thread, account: account, assignee: thread_assignee)

    deal = described_class.new(
      account: account,
      actor: actor,
      params: {
        title: 'Thread deal',
        pipeline_id: pipeline.id,
        originating_communication_thread_id: communication_thread.id
      }
    ).perform

    expect(deal.owner).to eq(thread_assignee)
  end

  it 'falls back to a linked conversation assignee for a thread-sourced deal without a thread assignee' do
    create(:crm_stage, account: account, pipeline: pipeline, default: true)
    conversation_assignee = create(:user, account: account, role: :agent)
    communication_thread = create(:communication_thread, account: account, assignee: nil)
    conversation = create(
      :conversation,
      account: account,
      contact: communication_thread.contact,
      assignee: conversation_assignee,
      last_activity_at: 1.hour.ago
    )
    create(
      :communication_thread_conversation,
      account: account,
      communication_thread: communication_thread,
      conversation: conversation
    )

    deal = described_class.new(
      account: account,
      params: {
        title: 'Thread conversation owner deal',
        pipeline_id: pipeline.id,
        originating_communication_thread_id: communication_thread.id
      }
    ).perform

    expect(deal.owner).to eq(conversation_assignee)
  end

  it 'falls back to the actor for a new source deal without an assignee when owner_id is omitted' do
    create(:crm_stage, account: account, pipeline: pipeline, default: true)
    actor = create(:user, account: account, role: :agent)
    conversation = create(:conversation, account: account, assignee: nil)

    deal = described_class.new(
      account: account,
      actor: actor,
      params: {
        title: 'Actor-owned deal',
        pipeline_id: pipeline.id,
        originating_conversation_id: conversation.id
      }
    ).perform

    expect(deal.owner).to eq(actor)
  end

  it 'keeps a new deal unassigned when owner_id is explicitly blank' do
    create(:crm_stage, account: account, pipeline: pipeline, default: true)
    assignee = create(:user, account: account, role: :agent)
    conversation = create(:conversation, account: account, assignee: assignee)

    deal = described_class.new(
      account: account,
      params: {
        title: 'Explicitly unassigned deal',
        pipeline_id: pipeline.id,
        originating_conversation_id: conversation.id,
        owner_id: ''
      }
    ).perform

    expect(deal.owner).to be_nil
  end

  it 'does not assign an existing ownerless deal to the actor when owner_id is omitted on update' do
    actor = create(:user, account: account, role: :agent)
    deal = create(:crm_deal, account: account, pipeline: pipeline, owner: nil)

    updated_deal = described_class.new(
      account: account,
      actor: actor,
      deal: deal,
      params: {
        title: 'Still ownerless',
        lock_version: deal.lock_version
      }
    ).perform

    expect(updated_deal.owner).to be_nil
  end
end
