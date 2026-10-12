# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Playground::CustomerProfileTools, 'through the Playground tool executor' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant) }
  let(:tool_ids) { described_class::CUSTOMER_PROFILE_ARGUMENTS.keys }

  before do
    account.enable_features!('scheduling', 'crm_deals', 'crm_tasks')
    allow(assistant).to receive(:allowed_agent_tool_ids).and_return(tool_ids)
    allow(Captain::ToolSafety).to receive(:check_arguments!)
    allow(Captain::ToolSafety).to receive(:check_result!)
  end

  after { Current.reset }

  def invoke(trial, tool, **arguments)
    state = trial.state.merge(source: 'playground', account_id: account.id, assistant_id: assistant.id)
    context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: state, playground_session: trial }))
    result = Captain::Playground::ToolExecutor.new(trial).execute(tool, arguments, context: context)
    result = JSON.parse(result) if result.is_a?(String)
    trial.namespace.decode(result).deep_symbolize_keys
  end

  def add_deal(trial, id:, contact_id:, stage_id:, title:, **extra)
    trial.scenario.data['deals'] << { 'id' => id, 'contact_id' => contact_id, 'title' => title, 'amount' => 5000, 'currency' => 'KZT',
                                      'pipeline_id' => 901, 'stage_id' => stage_id, 'custom_attributes' => {} }.merge(extra.stringify_keys)
  end

  it 'has an explicit synthetic adapter for every customer profile tool' do
    expect(tool_ids.map { |id| Captain::Playground::ToolSupport.for_tool(id) }.uniq).to eq(['synthetic'])
  end

  it 'reads the synthetic caller profile with the production payload and refuses unknown arguments' do
    session.with_lock do |trial|
      caller = trial.scenario.contact
      result = invoke(trial, 'get_my_contact')

      expect(result).to include(success: true, simulated: true)
      expect(result[:contact]).to include(id: caller['id'], iin: '900101400013', birth_date: '1990-01-01',
                                          phone_number: caller['phone_number'], email: caller['email'])
      expect(invoke(trial, 'get_my_contact', contact_id: 102)[:success]).to be(false)
    end
  end

  it 'updates only the caller through the production field rules and leaves the scenario untouched on a rejected value' do
    session.with_lock do |trial|
      result = invoke(trial, 'update_my_contact', first_name: '  Updated ', birth_date: '1991-02-03', gender: 'FEMALE', email: 'new@example.test')

      expect(result).to include(success: true, simulated: true)
      expect(result[:contact]).to include(first_name: 'Updated', birth_date: '1991-02-03', gender: 'female', email: 'new@example.test')
      expect(trial.scenario.contact).to include('name' => 'Updated', 'email' => 'new@example.test')

      original = trial.scenario.data.deep_dup
      [{ iin: '123456789012' }, { birth_date: '2026-02-30' }, { gender: 'other' }, { email: 'invalid-email' },
       { contact_id: 102, first_name: 'Wrong' }].each do |arguments|
        expect(invoke(trial, 'update_my_contact', **arguments)).to include(success: false, reason: 'validation_error')
      end
      expect(trial.scenario.data).to eq(original)
    end
  end

  it 'lists only the caller deals with the production status, pipeline and paging rules' do
    session.with_lock do |trial|
      add_deal(trial, id: 502, contact_id: 101, stage_id: 913, title: 'Won deal', updated_at: '2026-10-01T10:00:00+05:00')
      add_deal(trial, id: 503, contact_id: 102, stage_id: 911, title: 'Deal of the son')

      all = invoke(trial, 'list_my_deals')
      expect(all).to include(success: true, total: 2, limit: 10, offset: 0, has_more: false)
      expect(all[:deals].map { |deal| deal[:id] }).to eq([502, 501])
      expect(all[:deals].first).to include(title: 'Won deal', pipeline: 'Записи', stage: 'Завершён', status: 'won', amount: 5000, currency: 'KZT')

      expect(invoke(trial, 'list_my_deals', status: 'open')[:deals].map { |deal| deal[:id] }).to eq([501])
      expect(invoke(trial, 'list_my_deals', status: 'won')[:deals].map { |deal| deal[:id] }).to eq([502])
      expect(invoke(trial, 'list_my_deals', status: 'lost')[:deals]).to eq([])
      expect(invoke(trial, 'list_my_deals', pipeline: 'BOOKINGS')[:total]).to eq(2)
      expect(invoke(trial, 'list_my_deals', pipeline: 'unknown')[:total]).to eq(0)

      first_page = invoke(trial, 'list_my_deals', limit: 1)
      expect(first_page).to include(total: 2, limit: 1, has_more: true)
      expect(invoke(trial, 'list_my_deals', limit: 1, offset: 1)).to include(has_more: false)
      expect(invoke(trial, 'list_my_deals', limit: 0)).to include(success: false, reason: 'validation_error')
      expect(invoke(trial, 'list_my_deals', status: 'archived')).to include(success: false, reason: 'validation_error')
    end
  end

  it 'never routes the customer profile tools to real data, even with real-data permissions enabled' do
    session.with_lock do |trial|
      trial.set_permissions!(read: true, write: true)
      executor = Captain::Playground::RealToolExecutor.new(trial)

      tool_ids.each { |id| expect(executor.synthetic?(id, {})).to be(true) }
    end
  end
end
