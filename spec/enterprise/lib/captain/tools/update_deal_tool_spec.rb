require 'rails_helper'

RSpec.describe Captain::Tools::UpdateDealTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns normalized update_deal payload' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#111111')
    deal = create(:crm_deal, account: account, title: 'Old title', pipeline: pipeline, stage: stage, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: deal.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, title: 'New title', amount: '200.00', currency: 'USD'))

    expect(payload).to include('action' => 'update_deal', 'deal_id' => deal.id)
    expect(payload['deal']).to include('id' => deal.id, 'title' => 'New title', 'amount' => '200')
    expect(payload['deal']).not_to have_key('amount_minor')
    expect(payload.to_json).not_to include('20000')
  end

  it 'updates and moves the deal to a selected pipeline stage' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    deal = create(:crm_deal, account: account, originating_conversation_id: conversation.id)
    target_pipeline = create(:crm_pipeline, account: account, code: 'expansion')
    target_stage = create(:crm_stage, account: account, pipeline: target_pipeline, code: 'work', position: 1, color: '#111111')
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: deal.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, title: 'Moved deal', pipeline_code: 'expansion', stage_code: 'work'))

    expect(payload).to include('deal_id' => deal.id, 'pipeline_id' => target_pipeline.id, 'stage_id' => target_stage.id)
    expect(payload['deal']).to include('id' => deal.id, 'title' => 'Moved deal', 'pipeline_id' => target_pipeline.id, 'stage_id' => target_stage.id)
  end

  it 'updates and moves the deal without a transition reason' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    pipeline = create(:crm_pipeline, account: account)
    current_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'new', position: 1, color: '#111111')
    target_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      code: 'work',
      position: 2,
      color: '#222222'
    )
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: current_stage, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: deal.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, title: 'Moved deal', stage_code: 'work'))
    event = deal.reload.events.where(event_type: 'deal_stage_changed').last

    expect(payload['deal']).to include('id' => deal.id, 'title' => 'Moved deal', 'stage_id' => target_stage.id)
    expect(event.meta).not_to have_key('transition_reason')
  end

  it 'updates an explicit deal_id instead of the current conversation deal' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#111111')
    current_deal = create(
      :crm_deal,
      account: account,
      title: 'Current linked deal',
      pipeline: pipeline,
      stage: stage,
      originating_conversation_id: conversation.id
    )
    target_deal = create(:crm_deal, account: account, title: 'Target deal', pipeline: pipeline, stage: stage)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: current_deal.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, deal_id: target_deal.id, title: 'Updated target deal'))

    expect(payload).to include('action' => 'update_deal', 'deal_id' => target_deal.id)
    expect(payload['deal']).to include('id' => target_deal.id, 'title' => 'Updated target deal')
    expect(target_deal.reload.title).to eq('Updated target deal')
    expect(current_deal.reload.title).to eq('Current linked deal')
  end

  it 'keeps an explicitly selected deal across a short follow-up value turn' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#111111')
    current_deal = create(
      :crm_deal,
      account: account,
      title: 'Current linked deal',
      pipeline: pipeline,
      stage: stage,
      originating_conversation_id: conversation.id
    )
    target_deal = create(:crm_deal, account: account, title: 'Номер клиента', pipeline: pipeline, stage: stage)
    create(:crm_deal_contact, account: account, deal: target_deal, contact: contact, primary: true)
    tool_context = Struct.new(:state).new(
      {
        conversation: { id: conversation.id },
        deal: { id: current_deal.id },
        contact: { id: contact.id },
        selected_deal_context: {
          deal_id: target_deal.id,
          account_id: account.id,
          conversation_id: conversation.id,
          contact_id: contact.id,
          selected_at: Time.current.iso8601
        }
      }
    )
    create(:message, conversation: conversation, message_type: :incoming, content: 'Переименуй сделку Номер клиента')
    create(:message, conversation: conversation, message_type: :incoming, content: 'Назови её Новый проект')

    payload = JSON.parse(tool.perform(tool_context, deal_id: target_deal.id, title: 'Новый проект'))

    expect(payload).to include('action' => 'update_deal', 'deal_id' => target_deal.id)
    expect(target_deal.reload.title).to eq('Новый проект')
    expect(current_deal.reload.title).to eq('Current linked deal')
  end

  it 'rejects a prior-message deal reference without a server-selected deal context' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    target_deal = create(:crm_deal, account: account, title: 'Номер клиента')
    create(:crm_deal_contact, account: account, deal: target_deal, contact: contact, primary: true)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } })
    create(:message, conversation: conversation, message_type: :incoming, content: 'Переименуй сделку Номер клиента')
    create(:message, conversation: conversation, message_type: :incoming, content: 'Назови её Новый проект')

    result = tool.perform(tool_context, deal_id: target_deal.id, title: 'Новый проект')

    expect(result).to include('ERROR:', Captain::Tools::Operations::DealUpdateGuard::ERROR_MESSAGE)
    expect(target_deal.reload.title).to eq('Номер клиента')
  end

  it 'rejects an expired server-selected deal context' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    target_deal = create(:crm_deal, account: account, title: 'Номер клиента')
    create(:crm_deal_contact, account: account, deal: target_deal, contact: contact, primary: true)
    tool_context = Struct.new(:state).new(
      {
        conversation: { id: conversation.id },
        contact: { id: contact.id },
        selected_deal_context: {
          deal_id: target_deal.id,
          account_id: account.id,
          conversation_id: conversation.id,
          contact_id: contact.id,
          selected_at: 3.minutes.ago.iso8601
        }
      }
    )
    create(:message, conversation: conversation, message_type: :incoming, content: 'Назови её Новый проект')

    result = tool.perform(tool_context, deal_id: target_deal.id, title: 'Новый проект')

    expect(result).to include('ERROR:', Captain::Tools::Operations::DealUpdateGuard::ERROR_MESSAGE)
    expect(target_deal.reload.title).to eq('Номер клиента')
  end

  it 'rejects a follow-up update when the latest deal reference selects another deal' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#111111')
    current_deal = create(
      :crm_deal,
      account: account,
      title: 'Current linked deal',
      pipeline: pipeline,
      stage: stage,
      originating_conversation_id: conversation.id
    )
    target_deal = create(:crm_deal, account: account, title: 'Номер клиента', pipeline: pipeline, stage: stage)
    other_deal = create(:crm_deal, account: account, title: 'Другая сделка', pipeline: pipeline, stage: stage)
    create(:crm_deal_contact, account: account, deal: target_deal, contact: contact, primary: true)
    create(:crm_deal_contact, account: account, deal: other_deal, contact: contact)
    tool_context = Struct.new(:state).new(
      {
        conversation: { id: conversation.id },
        deal: { id: current_deal.id },
        contact: { id: contact.id },
        selected_deal_context: {
          deal_id: target_deal.id,
          account_id: account.id,
          conversation_id: conversation.id,
          contact_id: contact.id,
          selected_at: Time.current.iso8601
        }
      }
    )
    create(:message, conversation: conversation, message_type: :incoming, content: 'Переименуй сделку Номер клиента')
    create(:message, conversation: conversation, message_type: :incoming, content: 'Нет, сделку Другая сделка')

    result = tool.perform(tool_context, deal_id: target_deal.id, title: 'Новый проект')

    expect(result).to include('ERROR:', Captain::Tools::Operations::DealUpdateGuard::ERROR_MESSAGE)
    expect(target_deal.reload.title).to eq('Номер клиента')
  end

  it 'ignores zero pipeline and stage ID placeholders while preserving real numeric field updates' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#111111')
    deal = create(:crm_deal, account: account, title: 'Old title', pipeline: pipeline, stage: stage, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: deal.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, title: 'Zero amount deal', amount: 0, currency: 'KZT', pipeline_id: '0', stage_id: 0))

    expect(payload).to include('action' => 'update_deal', 'deal_id' => deal.id, 'pipeline_id' => pipeline.id, 'stage_id' => stage.id)
    expect(payload['deal']).to include('id' => deal.id, 'title' => 'Zero amount deal', 'amount' => '0')
    expect(deal.reload).to have_attributes(pipeline_id: pipeline.id, stage_id: stage.id, amount_minor: 0)
  end
end
