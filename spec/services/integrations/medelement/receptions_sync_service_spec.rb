require 'rails_helper'

RSpec.describe Integrations::Medelement::ReceptionsSyncService do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:configuration) do
    instance_double(
      Integrations::Medelement::Configuration,
      sync_patients?: false,
      receptions_days_back: 3,
      receptions_days_forward: 70,
      throttle_ms: 0,
      time_zone: 'Asia/Almaty'
    )
  end
  let(:service) { described_class.new(account: account, client: client, configuration: configuration) }
  let!(:resource) do
    create(
      :scheduling_resource,
      account: account,
      timezone: 'Asia/Almaty',
      custom_attributes: {
        'medelement_specialist_code' => '27492901726817790',
        'medelement_cabinets' => [{ 'companyCabinetCode' => '37413011726129875' }]
      }
    )
  end
  let(:reception_payload) do
    [
      {
        'RECEPTION_CODE' => '975592971773905133',
        'PATIENT_CODE' => '550990851604984873',
        'STARTTIME' => '2026-03-21 09:00:00',
        'ENDTIME' => '2026-03-21 09:20:00',
        'ACTIVE' => 1,
        'REMOVED' => 0,
        'CREATED_AT' => '2026-03-19 12:25:33',
        'COMPANY_CABINET_CODE' => '37413011726129875'
      }
    ]
  end

  before do
    allow(client).to receive(:get_receptions).and_return(reception_payload)
  end

  it 'creates imported appointments without touching overlapping manual appointments' do
    travel_to(Time.zone.parse('2026-03-20 10:00:00')) do
      create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        starts_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 21, 9, 0, 0),
        ends_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 21, 9, 20, 0)
      )

      expect { service.perform }.to change { account.scheduling_appointments.where(source: 'medelement').count }.by(1)
      expect(account.scheduling_appointments.where(source: 'manual').count).to eq(1)
    end
  end

  it 'deletes stale Medelement appointments that are missing from the snapshot while keeping manual ones' do
    travel_to(Time.zone.parse('2026-03-20 10:00:00')) do
      stale_imported = create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        source: 'medelement',
        external_ref: 'medelement:reception:old',
        starts_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 9, 0, 0),
        ends_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 9, 20, 0),
        client_name: 'Imported'
      )
      manual = create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        starts_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 9, 30, 0),
        ends_at: ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 22, 10, 0, 0)
      )

      service.perform

      expect(account.scheduling_appointments.exists?(stale_imported.id)).to be(false)
      expect(account.scheduling_appointments.exists?(manual.id)).to be(true)
    end
  end
end
