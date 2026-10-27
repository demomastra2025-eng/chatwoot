require 'rails_helper'

# The patient agent gets the catalog search without the verification labels that name no action for it (eligibility_status on the
# answer, service_eligibility_status on the price rows); staff and Copilot keep them. All data is synthetic.
RSpec.describe Captain::Tools::Account::SearchSchedulingServicesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }
  let!(:primary) { create(:scheduling_service, account: account, name: 'Консультация терапевта первичная', base_price: 15_000) }
  let(:doctor) { create(:scheduling_resource, account: account, name: 'Асланова Айгерим') }

  before do
    account.enable_features!('scheduling')
    stub_embedder(account, 'консультация терапевта' => unit_vector(0))
    index_service(primary, vector_at(0, 0.9))
    create(:scheduling_service_price, account: account, service: primary, resource: doctor, price: 20_000, active: true)
  end

  def search(**arguments)
    JSON.parse(tool.execute(**arguments))
  end

  def as_agent
    tool.patient_scope = Captain::Tools::Agent::PatientScope.new(assistant: assistant, conversation: conversation)
  end

  it 'keeps the verification labels for staff and Copilot' do
    payload = search(queries: ['консультация терапевта'])

    expect(payload).to include('eligibility_status' => 'unverified')
    expect(payload['results'].first['services'].first['prices'].pluck('service_eligibility_status')).to eq(['price_link_unverified'])
  end

  it 'leaves the verification labels out of the answer of the patient agent and keeps the price' do
    as_agent

    payload = search(queries: ['консультация терапевта'])
    entry = payload['results'].first['services'].first

    expect(payload.keys).to eq(['results'])
    expect(entry).to include('id' => primary.id, 'name' => primary.name, 'price' => primary.base_price)
    expect(entry['doctors']).to eq(["#{doctor.id} Асланова Айгерим (20000)"])
    expect(entry.keys).to contain_exactly('id', 'name', 'price', 'duration_min', 'doctors', 'score')
  end

  it 'adds no instruction to the answer: how to read the matches is said once, in the text of the tool' do
    as_agent

    expect(search(queries: ['консультация терапевта']).to_s).not_to match(/instruction/)
  end
end
