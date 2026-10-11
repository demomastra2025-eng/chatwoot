require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ListMyDealsService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:pipeline) { create(:crm_pipeline, account: account, name: 'Clinic') }
  let(:other_pipeline) { create(:crm_pipeline, account: account, name: 'Other') }
  let(:open_stage) { create(:crm_stage, account: account, pipeline: pipeline, outcome: 'open') }
  let(:won_stage) { create(:crm_stage, account: account, pipeline: pipeline, outcome: 'won') }
  let(:lost_stage) { create(:crm_stage, account: account, pipeline: other_pipeline, outcome: 'lost') }
  let(:tool_context) { Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {}) }

  before { account.enable_features!('crm_deals') }

  def linked_deal(stage:, **attributes)
    deal = create(:crm_deal, account: account, pipeline: stage.pipeline, stage: stage, **attributes)
    create(:crm_deal_contact, account: account, contact: contact, deal: deal)
    deal
  end

  def call_tool(**arguments)
    adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'list_my_deals')
    JSON.parse(adapter.execute(tool_context, **arguments))
  end

  it 'returns only the current contact deals and compact cards' do
    account.update!(reporting_timezone: 'Europe/Moscow')
    own = linked_deal(stage: open_stage, title: 'Consultation', amount_minor: 25_000, currency: 'KZT')
    foreign = create(:crm_deal, account: account, pipeline: pipeline, stage: open_stage, title: 'Private')
    create(:crm_deal_contact, account: account, deal: foreign, contact: create(:contact, account: account))
    create(:crm_deal, account: create(:account))

    payload = call_tool

    expect(payload).to include('success' => true, 'total' => 1, 'limit' => 10, 'offset' => 0, 'has_more' => false)
    expect(payload.fetch('deals')).to contain_exactly(
      include('id' => own.id, 'title' => 'Consultation', 'pipeline' => 'Clinic', 'status' => 'open',
              'amount' => '250', 'currency' => 'KZT', 'updated_at' => a_string_ending_with('+03:00'))
    )
    expect(payload.to_json).not_to include('Private', 'amount_minor', 'deal_contacts')
  end

  it 'filters by status and pipeline' do
    open_deal = linked_deal(stage: open_stage, updated_at: 1.hour.ago)
    won = linked_deal(stage: won_stage, closed_at: 1.day.ago, updated_at: 2.hours.ago)
    lost = linked_deal(stage: lost_stage, closed_at: 2.days.ago, updated_at: 3.hours.ago)

    expect(call_tool(status: 'open')['deals'].pluck('id')).to eq([open_deal.id])
    expect(call_tool(status: 'won')['deals'].pluck('id')).to eq([won.id])
    expect(call_tool(status: 'lost')['deals'].pluck('id')).to eq([lost.id])
    expect(call_tool(pipeline: 'Clinic')['deals'].pluck('id')).to eq([open_deal.id, won.id])
    expect(call_tool(pipeline: pipeline.id)['deals'].pluck('id')).to eq([open_deal.id, won.id])
  end

  it 'pages in stable order and caps the limit' do
    open_deal = linked_deal(stage: open_stage, updated_at: 1.hour.ago)
    won = linked_deal(stage: won_stage, closed_at: 1.day.ago, updated_at: 2.hours.ago)
    linked_deal(stage: lost_stage, closed_at: 2.days.ago, updated_at: 3.hours.ago)

    first = call_tool(status: 'any', limit: 1)
    second = call_tool(status: 'any', limit: 1, offset: 1)
    expect(first).to include('total' => 3, 'has_more' => true)
    expect(first['deals'].pluck('id')).to eq([open_deal.id])
    expect(second['deals'].pluck('id')).to eq([won.id])
    expect(call_tool(limit: 200)['limit']).to eq(20)
    expect(call_tool(offset: 3)).to include('has_more' => false, 'deals' => [])
  end

  it 'returns neutral errors for invalid arguments and missing current contact' do
    expect(call_tool(status: 'unknown')).to eq('success' => false, 'reason' => 'validation_error')
    expect(call_tool(limit: -1)).to eq('success' => false, 'reason' => 'validation_error')
    expect(call_tool(offset: -1)).to eq('success' => false, 'reason' => 'validation_error')

    context = Struct.new(:state, :context).new({ conversation: { id: 2_147_483_647 } }, {})
    adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'list_my_deals')
    expect(JSON.parse(adapter.execute(context))).to eq('success' => false, 'reason' => 'not_found')
  end
end
