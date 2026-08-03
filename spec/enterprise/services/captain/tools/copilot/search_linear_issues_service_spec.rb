require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchLinearIssuesService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let(:linear_service) { instance_double(Integrations::Linear::ProcessorService) }

  before do
    create(:integrations_hook, :linear, account: account)
    allow(Integrations::Linear::ProcessorService).to receive(:new).and_return(linear_service)
    allow(linear_service).to receive(:search_issue).and_return({
                                                                 data: [
                                                                   {
                                                                     'id' => 'TEST-123',
                                                                     'title' => 'Broken sync',
                                                                     'description' => 'Webhook sync is broken',
                                                                     'priority' => 2,
                                                                     'state' => { 'name' => 'In Progress' },
                                                                     'assignee' => { 'name' => 'John Doe' }
                                                                   }
                                                                 ]
                                                               })
  end

  it 'returns normalized issues payload' do
    payload = JSON.parse(service.execute(term: 'sync', limit: 5))

    expect(payload['filters']).to include('term' => 'sync')
    expect(payload['total_count']).to eq(1)
    expect(payload['issues'].first).to include(
      'id' => 'TEST-123',
      'title' => 'Broken sync',
      'state' => 'In Progress',
      'priority' => 'High',
      'assignee_name' => 'John Doe'
    )
  end

  it 'returns a controlled failure when the integration is not active' do
    account.hooks.destroy_all

    expect(service.execute(term: 'sync')).to eq('ERROR: ArgumentError: Linear integration is not enabled')
    expect(linear_service).not_to have_received(:search_issue)
  end
end
