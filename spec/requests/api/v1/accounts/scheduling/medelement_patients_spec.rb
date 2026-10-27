require 'rails_helper'

RSpec.describe 'Scheduling MedElement patients API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/medelement_patients" }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:iin) do
    digits = '00010150000'.chars.map(&:to_i)
    checksum = Scheduling::IinValidator::FIRST_WEIGHTS.each_with_index.sum { |weight, index| weight * digits[index] } % 11
    checksum = Scheduling::IinValidator::SECOND_WEIGHTS.each_with_index.sum { |weight, index| weight * digits[index] } % 11 if checksum == 10
    "#{digits.join}#{checksum == 10 ? 0 : checksum}"
  end
  let(:card) { { 'PROFILE_CODE' => 'fake-code-1', 'NAME' => 'Аян', 'LASTNAME' => 'Қуаныш', 'IIN' => iin } }

  before do
    account.enable_features!('scheduling')
    hook
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
  end

  it 'searches by IIN in a filtered body without logging its digits' do
    allow(client).to receive(:search_patients_by_iin).with(iin: iin).and_return([card])
    output = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    post "#{path}/search", params: { query: iin }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'patients', 0, 'iin_masked')).to eq("••••#{iin.last(4)}")
    expect(output.string).not_to include(iin)
  ensure
    Rails.logger = previous_logger
  end

  it 'imports a chosen card and returns the scheduling contact shape' do
    allow(client).to receive(:search_patients_by_name).and_return([card])
    post "#{path}/search", params: { query: 'Қуаныш' }, headers: headers, as: :json
    token = response.parsed_body.dig('payload', 'patients', 0, 'token')
    contact = create(:contact, account: account, name: 'Аян', last_name: 'Қуаныш', custom_attributes: { 'medelement_patient_code' => 'fake-code-1' })
    allow(client).to receive(:get_patient).with(patient_code: 'fake-code-1').and_return(card)
    sync = instance_double(Integrations::Medelement::PatientsSyncService,
                           sync_patient_codes: { 'fake-code-1' => contact })
    allow(Integrations::Medelement::PatientsSyncService).to receive(:new).and_return(sync)

    post path, params: { token: token }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'id')).to eq(contact.id)
  end

  it 'rejects a changed token and a disabled hook' do
    post path, params: { token: 'changed' }, headers: headers, as: :json
    expect(response.parsed_body['code']).to eq('MEDELEMENT_PATIENT_TOKEN_INVALID')

    hook.update!(status: :disabled)
    post "#{path}/search", params: { query: 'Қуаныш' }, headers: headers, as: :json
    expect(response.parsed_body['code']).to eq('SCHEDULING_PROVIDER_NOT_CONFIGURED')
  end
end
