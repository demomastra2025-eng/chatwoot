require 'rails_helper'

# The patient agent gets the catalog search without the verification labels that name no action for it (eligibility_status on the
# answer, service_eligibility_status on the price rows); staff and Copilot keep them. A name that differs from the request is
# the agent's own choice, not a question for the patient. All data is synthetic.
RSpec.describe Captain::Tools::Copilot::SearchSchedulingServicesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }
  let!(:primary) { create(:scheduling_service, account: account, name: 'Консультация терапевта первичная') }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_service_price, account: account, service: primary, resource: create(:scheduling_resource, account: account), active: true)
  end

  def search(**arguments)
    JSON.parse(tool.execute(**arguments))
  end

  def as_agent
    tool.patient_scope = Captain::Tools::Agent::PatientScope.new(assistant: assistant, conversation: conversation)
  end

  it 'keeps the verification labels for staff and Copilot' do
    payload = search(query: 'консультация терапевта')

    expect(payload).to include('eligibility_status' => 'unverified')
    expect(payload['services'].first['prices'].pluck('service_eligibility_status')).to eq(['price_link_unverified'])
  end

  it 'leaves the verification labels out of the answer of the patient agent and keeps the price' do
    as_agent

    payload = search(query: 'консультация терапевта')
    price_row = payload['services'].first['prices'].first

    expect(payload).not_to have_key('eligibility_status')
    expect(payload).to include('match_status' => 'candidate', 'total_count' => 1)
    expect(price_row).not_to have_key('service_eligibility_status')
    expect(price_row).to include('price', 'resource_id')
  end

  describe 'the ambiguous flag' do
    it 'stays in the answer for staff and Copilot, also for a single partial match' do
      expect(search(query: 'консультация терапевта срочная')).to include('match_status' => 'partial_candidates', 'ambiguous' => true)
    end

    it 'is left out of the answer of the patient agent: it would sit next to the instruction to choose the best match itself' do
      as_agent

      payload = search(query: 'консультация терапевта срочная')

      expect(payload).to include('match_status' => 'partial_candidates', 'total_count' => 1)
      expect(payload).not_to have_key('ambiguous')
      expect(payload['instruction']).to eq(described_class::NAME_DIFFERS_INSTRUCTION)
    end
  end

  describe 'a name that differs from the request' do
    before { create(:scheduling_service, account: account, name: 'Консультация терапевта повторная') }

    it 'tells the agent to choose the best match itself and to ask only when several entries fit equally' do
      payload = search(query: 'консультация терапевта')

      expect(payload).to include('match_status' => 'ambiguous', 'exact_name_matches' => 0)
      expect(payload['instruction']).to eq(described_class::NAME_DIFFERS_INSTRUCTION)
      expect(payload['instruction']).to include('Choose the best match from the patient\'s words')
        .and include('use its exact name in your reply or booking')
        .and include('Ask the patient only when two or more entries fit equally')
      expect(payload['instruction']).not_to match(/confirm|never/i)
    end
  end
end
