require 'rails_helper'

RSpec.describe Integrations::Medelement::PatientDirectorySearch do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:service) { described_class.new(account: account, hook: hook, user: user, client: client) }
  let(:iin) do
    digits = '00010150000'.chars.map(&:to_i)
    checksum = Scheduling::IinValidator::FIRST_WEIGHTS.each_with_index.sum { |weight, index| weight * digits[index] } % 11
    checksum = Scheduling::IinValidator::SECOND_WEIGHTS.each_with_index.sum { |weight, index| weight * digits[index] } % 11 if checksum == 10
    "#{digits.join}#{checksum == 10 ? 0 : checksum}"
  end
  let(:row) do
    { 'PROFILE_CODE' => 'fake-patient-1', 'NAME' => 'Аян', 'LASTNAME' => 'Қуаныш', 'MIDDLENAME' => 'Болатұлы',
      'IIN' => iin, 'BIRTHDAY' => '01.01.2000', 'PATIENT_PHONE_2' => '', 'PHONES_STR' => '' }
  end

  it 'searches a valid IIN exactly and keeps the unmasked value out of the response' do
    allow(client).to receive(:search_patients_by_iin).with(iin: iin).and_return([row])

    result = service.search(iin)

    expect(result[:patients].first).to include(full_name: 'Қуаныш Аян Болатұлы', iin_masked: "••••#{iin.last(4)}", phone_known: false)
    expect(result.to_json).not_to include(iin)
  end

  it 'does not send bad IINs or mixed letters and digits to the provider' do
    expect(client).not_to receive(:search_patients_by_iin)
    expect(client).not_to receive(:search_patients_by_phone)
    expect(client).not_to receive(:search_patients_by_name)

    invalid_iin = "#{iin.first(11)}#{(iin.last.to_i + 1) % 10}"
    expect(service.search(invalid_iin)[:reason]).to eq('invalid_iin')
    expect(service.search('Аян 123')[:reason]).to eq('unsupported')
  end

  it 'uses the normalized Kazakhstan phone and only one request' do
    expect(client).to receive(:search_patients_by_phone).with(phone_number: '+77010000001').and_return([row])
    expect(service.search('8 (701) 000-00-01')[:patients].size).to eq(1)
  end

  it 'tries reversed name fields only when the first interpretation is empty' do
    expect(client).to receive(:search_patients_by_name).ordered.with(lastname: 'Аян', name: 'Қуаныш', middlename: 'Болатұлы').and_return([])
    expect(client).to receive(:search_patients_by_name).ordered.with(lastname: 'Болатұлы', name: 'Аян', middlename: 'Қуаныш').and_return([row])
    expect(service.search('Аян Қуаныш Болатұлы')[:patients].size).to eq(1)
  end

  it 'drops removed and duplicate codes, then limits visible rows' do
    rows = Array.new(22) { |index| row.merge('PROFILE_CODE' => "fake-#{index}") }
    allow(client).to receive(:search_patients_by_name).and_return(rows + [rows.first, row.merge('REMOVED' => 1)])

    result = service.search('Қуаныш')

    expect(result[:patients].size).to eq(20)
    expect(result[:truncated]).to be(true)
  end

  it 'ends both name interpretations within one five-second deadline' do
    elapsed = 0.0
    deadline = Integrations::Medelement::RequestDeadline.new(seconds: 5, clock: -> { elapsed })
    bounded = described_class.new(account: account, hook: hook, user: user, client: client, deadline: deadline)
    allow(client).to receive(:search_patients_by_name) do
      elapsed += 2.6
      []
    end

    expect { bounded.search('Қуаныш') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_PATIENT_SEARCH_UNAVAILABLE')
    end
    expect(client).to have_received(:search_patients_by_name).twice
  end

  it 'uses a fresh card through the sync resolver and rejects a foreign token' do
    allow(client).to receive(:search_patients_by_name).and_return([row])
    token = service.search('Қуаныш')[:patients].first[:token]
    contact = create(:contact, account: account, name: 'Аян')
    card = row.merge('PATIENT_PHONE_2' => '+77010000001')
    allow(client).to receive(:get_patient).with(patient_code: 'fake-patient-1').and_return(card)
    sync = instance_double(Integrations::Medelement::PatientsSyncService)
    allow(Integrations::Medelement::PatientsSyncService).to receive(:new).and_return(sync)
    expect(sync).to receive(:sync_patient_codes).with(
      ['fake-patient-1'], prefetched_patients: { 'fake-patient-1' => card }, require_verified_card: true
    ).and_return('fake-patient-1' => contact)
    expect(service.import(token)).to eq(contact)
    expect { service.import("#{token}tampered") }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_PATIENT_TOKEN_INVALID')
    end
  end
end
