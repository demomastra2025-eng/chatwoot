require 'rails_helper'

RSpec.describe Captain::Tools::Account::GetDealService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns a normalized deal payload' do
    company = create(:company, account: account, name: 'OneLink')
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Qualified')
    deal = create(:crm_deal, account: account, title: 'Enterprise renewal', company: company, pipeline: pipeline, stage: stage)

    payload = JSON.parse(service.execute(deal_id: deal.id))

    expect(payload['deal']).to include(
      'id' => deal.id,
      'title' => 'Enterprise renewal',
      'company_id' => company.id,
      'pipeline_id' => pipeline.id,
      'stage_id' => stage.id
    )
  end

  it 'rejects invalid deal IDs instead of silently returning not found' do
    expect { service.execute(deal_id: { name: 'get_deal', parameters: { wrong_id: 52 } }) }
      .to raise_error(ArgumentError, 'deal_id is required')
  end

  it 'returns a structured failure when the deal is missing' do
    expect(service.execute(deal_id: 999)).to eq('ERROR: Deal not found')
  end

  it 'limits customer-agent direct IDs to deals of the current contact' do
    conversation = create(:conversation, account: account)
    current_deal = create(:crm_deal, account: account)
    create(:crm_deal_contact, account: account, deal: current_deal, contact: conversation.contact, primary: true)
    other_deal = create(:crm_deal, account: account)
    customer_service = described_class.new(
      assistant,
      user: assistant,
      conversation: conversation,
      execution_scope: Captain::ToolAccess::SCOPE_AGENT
    )

    expect(JSON.parse(execute_as_agent(customer_service, deal_id: current_deal.id)).dig('deal', 'id')).to eq(current_deal.id)
    expect(execute_as_agent(customer_service, deal_id: other_deal.id)).to eq('ERROR: Deal not found')
  end

  def execute_as_agent(tool, **params)
    execute_method = tool.method(:execute)
    execute_method = execute_method.super_method if execute_method.owner == Captain::Tools::Instrumentation
    execute_method.call(**params)
  end
end
