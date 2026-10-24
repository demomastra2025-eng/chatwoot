require 'rails_helper'

# Which specialists perform a MedElement service, and how long the visit lasts, comes from the visit history
# (Scheduling::ResourceServiceStat); MedElement gives neither through its API.
RSpec.describe Scheduling::AvailableSlotSearchService do
  let(:account) { create(:account) }
  let(:time_zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:doctor_a) { create(:scheduling_resource, account: account, name: 'Anar', timezone: 'Asia/Almaty', slot_duration_min: 15) }
  let(:doctor_b) { create(:scheduling_resource, account: account, name: 'Berik', timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:doctor_c) { create(:scheduling_resource, account: account, name: 'Dana', timezone: 'Asia/Almaty', slot_duration_min: 20) }
  # duration_min 30 is the column default of every imported MedElement service, not a real length
  let(:ultrasound) do
    create(:scheduling_service, account: account, name: 'УЗИ малого таза', duration_min: 30,
                                custom_attributes: { 'medelement_nomenclature_code' => 'U1' })
  end
  let(:from_time) { time_zone.local(2026, 4, 20, 9, 0, 0) }
  let(:to_time) { time_zone.local(2026, 4, 20, 10, 0, 0) }

  before do
    [doctor_a, doctor_b, doctor_c].each do |doctor|
      create(:scheduling_work_rule, account: account, resource: doctor, weekday: 1, start_minute: 9 * 60, end_minute: 11 * 60)
    end
  end

  def perform(**attributes)
    described_class.new(account: account, from: from_time, to: to_time, **attributes).perform
  end

  def pair(resource, status: 'auto', median: 15, service: ultrasound)
    create(:scheduling_resource_service_stat, account: account, resource: resource, service: service, status: status,
                                              median_duration_min: median)
  end

  describe 'a service searched without a specialist' do
    it 'searches the specialists with an auto or confirmed pair, and no others' do
      pair(doctor_a, status: 'auto')
      pair(doctor_b, status: 'confirmed')

      payload = perform(service_id: ultrasound.id)

      expect(payload[:resources].pluck(:id)).to eq([doctor_a.id, doctor_b.id])
      expect(payload[:candidate_resource_ids]).to eq([doctor_a.id, doctor_b.id])
      expect(payload[:slots].pluck(:resource_id).uniq).to contain_exactly(doctor_a.id, doctor_b.id)
    end

    it 'skips a disabled or a stale pair' do
      pair(doctor_a, status: 'auto')
      pair(doctor_b, status: 'disabled')
      pair(doctor_c, status: 'stale')

      expect(perform(service_id: ultrasound.id)[:resources].pluck(:id)).to eq([doctor_a.id])
    end

    it 'skips a specialist who cannot be booked' do
      pair(doctor_a)
      pair(doctor_b)
      doctor_b.update!(active: false)

      expect(perform(service_id: ultrasound.id)[:resources].pluck(:id)).to eq([doctor_a.id])
    end

    it 'still searches the specialists with an active price link' do
      pair(doctor_a)
      create(:scheduling_service_price, account: account, service: ultrasound, resource: doctor_c)

      expect(perform(service_id: ultrasound.id)[:resources].pluck(:id)).to eq([doctor_a.id, doctor_c.id])
    end

    it 'asks for the specialist first when no pair counts, and does not search every specialist' do
      pair(doctor_a, status: 'disabled')
      pair(doctor_b, status: 'stale')
      expect(Scheduling::ResourceAvailabilityQueryService).not_to receive(:new)

      expect { perform(service_id: ultrasound.id) }
        .to raise_error(described_class::ResourceSelectionRequiredError, described_class::RESOURCE_SELECTION_REQUIRED_ERROR)
    end

    it 'asks for the specialist first when the service has no pair at all' do
      expect { perform(service_id: ultrasound.id) }.to raise_error(described_class::ResourceSelectionRequiredError)
    end

    it 'does not use the pair of another service or of another account' do
      other_service = create(:scheduling_service, account: account, custom_attributes: { 'medelement_nomenclature_code' => 'U2' })
      pair(doctor_a, service: other_service)
      other_account = create(:account)
      create(:scheduling_resource_service_stat, account: other_account, service: create(:scheduling_service, account: other_account))

      expect { perform(service_id: ultrasound.id) }.to raise_error(described_class::ResourceSelectionRequiredError)
    end
  end

  describe 'the length of the visit of a MedElement service' do
    it 'is the median of the pair rounded up to the slot of each specialist, never the 30 minutes default' do
      pair(doctor_a, median: 10)
      pair(doctor_b, median: 10)

      by_doctor = perform(service_id: ultrasound.id)[:slots].group_by { |slot| slot[:resource_id] }

      expect(by_doctor.fetch(doctor_a.id).first)
        .to include(starts_at: '2026-04-20T09:00:00+05:00', ends_at: '2026-04-20T09:15:00+05:00', duration_min: 15)
      expect(by_doctor.fetch(doctor_b.id).first)
        .to include(starts_at: '2026-04-20T09:00:00+05:00', ends_at: '2026-04-20T09:30:00+05:00', duration_min: 30)
    end

    it 'gives no length for the whole answer when the specialists differ, each slot carries its own' do
      pair(doctor_a, median: 15)
      pair(doctor_c, median: 20)

      payload = perform(service_id: ultrasound.id)

      expect(payload).not_to have_key(:duration_min)
      expect(payload[:service]).not_to have_key(:duration_min)
      expect(payload[:slots].map { |slot| [slot[:resource_id], slot[:duration_min]] }.uniq)
        .to contain_exactly([doctor_a.id, 15], [doctor_c.id, 20])
    end

    it 'gives one length for the whole answer when the specialists share it' do
      doctor_c.update!(slot_duration_min: 15)
      pair(doctor_a, median: 15)
      pair(doctor_c, median: 12)

      payload = perform(service_id: ultrasound.id)

      expect(payload[:duration_min]).to eq(15)
      expect(payload[:service]).to include(duration_min: 15)
    end

    it 'is the slot of a specialist who is named but has no pair' do
      payload = perform(service_id: ultrasound.id, resource_ids: [doctor_c.id], limit: 2)

      expect(payload[:duration_min]).to eq(20)
      expect(payload[:slots].first).to include(resource_id: doctor_c.id, starts_at: '2026-04-20T09:00:00+05:00',
                                               ends_at: '2026-04-20T09:20:00+05:00', duration_min: 20)
    end

    it 'ignores a disabled pair for the length' do
      pair(doctor_a, status: 'disabled', median: 45)

      payload = perform(service_id: ultrasound.id, resource_ids: [doctor_a.id], limit: 1)

      expect(payload[:slots].first).to include(duration_min: 15)
    end

    it 'keeps a requested length and the own length of a local service' do
      pair(doctor_a, median: 45)
      local = create(:scheduling_service, account: account, name: 'Consultation', duration_min: 40)

      requested = perform(service_id: ultrasound.id, resource_ids: [doctor_a.id], duration_min: 20, limit: 1)
      own = perform(service_id: local.id, resource_ids: [doctor_a.id], limit: 1)

      expect(requested[:slots].first).to include(duration_min: 20)
      expect(own[:slots].first).to include(duration_min: 40)
      expect(own[:duration_min]).to eq(40)
    end
  end
end
