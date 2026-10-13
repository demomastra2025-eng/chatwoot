require 'rails_helper'

# The patient agent gets the specialist search without link_status, the label of how the service filter was applied, which names
# no action for it; the search status stays. Staff and Copilot keep link_status. A name that differs from the request is the
# agent's own choice, not a question for the patient. All data is synthetic.
RSpec.describe Captain::Tools::Copilot::SearchSchedulingResourcesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }
  let!(:specialist) { create(:scheduling_resource, account: account, name: 'Асланов Мурад Тестович', specialty: 'Хирург') }
  let!(:service_record) { create(:scheduling_service, account: account, name: 'Консультация хирурга') }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_service_price, account: account, service: service_record, resource: specialist, active: true)
  end

  def search(**arguments)
    JSON.parse(tool.execute(**arguments))
  end

  def as_agent
    tool.patient_scope = Captain::Tools::Agent::PatientScope.new(assistant: assistant, conversation: conversation)
  end

  it 'keeps link_status for staff and Copilot' do
    expect(search(service_id: service_record.id)).to include('link_status' => 'price_link_unverified', 'search_status' => 'candidates')
    expect(search(query: 'Асланов')).to include('link_status' => 'not_checked')
  end

  it 'leaves link_status out of the answer of the patient agent and keeps the search status and the specialists' do
    as_agent

    payload = search(service_id: service_record.id)

    expect(payload).not_to have_key('link_status')
    expect(payload).to include('search_status' => 'candidates', 'total_count' => 1)
    expect(payload['resources'].pluck('id')).to eq([specialist.id])
    expect(search(service_id: create(:scheduling_service, account: account, name: 'Без связей').id))
      .to include('search_status' => 'no_recorded_link', 'total_count' => 0)
  end

  describe 'a name that differs from the request' do
    before { create(:scheduling_resource, account: account, name: 'Асланов Мурад Другой', specialty: 'Хирург') }

    it 'tells the agent to choose the best match itself and to ask only when several entries fit equally' do
      payload = search(query: 'Асланов Мурад')

      expect(payload).to include('search_status' => 'ambiguous', 'exact_name_matches' => 0)
      expect(payload['instruction']).to eq(described_class::NAME_DIFFERS_INSTRUCTION)
      expect(payload['instruction']).to include('Choose the best match from the patient\'s words')
        .and include('use its exact name in your reply or booking')
        .and include('Ask the patient only when two or more entries fit equally')
      expect(payload['instruction']).not_to match(/confirm|never/i)
    end
  end
end
