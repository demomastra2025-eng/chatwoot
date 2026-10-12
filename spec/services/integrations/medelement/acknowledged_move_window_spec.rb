require 'rails_helper'

RSpec.describe Integrations::Medelement::AcknowledgedMoveWindow do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:old_start) { Time.utc(2026, 10, 14, 5, 0) }
  let(:old_end) { Time.utc(2026, 10, 14, 5, 30) }
  let(:new_start) { Time.utc(2026, 10, 14, 6, 0) }
  let(:new_end) { Time.utc(2026, 10, 14, 6, 30) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: contact, resource: resource, source: 'medelement',
                                    starts_at: new_start, ends_at: new_end, external_ref: 'medelement:reception:r-1',
                                    custom_attributes: { 'medelement_reception_code' => 'r-1' })
  end

  def acknowledged_move(executed_at: Time.current, status: 'succeeded')
    Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: contact, operation: 'move_reception', status: status,
      idempotency_key: "move-#{SecureRandom.hex(4)}", provider_reception_code: 'r-1', company_cabinet_code: 'cabinet-1',
      desired_starts_at: new_start, desired_ends_at: new_end, executed_at: executed_at,
      execution_state: { 'request_snapshot' => { 'reception' => {
        'source_starts_at' => old_start.iso8601(6), 'source_ends_at' => old_end.iso8601(6),
        'destination_starts_at' => new_start.iso8601(6), 'destination_ends_at' => new_end.iso8601(6)
      } } }
    )
  end

  describe '.stale_read?' do
    it 'recognises the pre-move interval within the window after the provider answered OK' do
      acknowledged_move

      expect(described_class.stale_read?(appointment, starts_at: old_start, ends_at: old_end)).to be(true)
    end

    it 'does not hold back the interval the provider confirmed' do
      acknowledged_move

      expect(described_class.stale_read?(appointment, starts_at: new_start, ends_at: new_end)).to be(false)
    end

    it 'does not hold back a third interval that somebody set in MedElement' do
      acknowledged_move

      expect(described_class.stale_read?(appointment, starts_at: old_start + 2.hours, ends_at: old_end + 2.hours)).to be(false)
    end

    it 'trusts the provider again once the window has passed' do
      acknowledged_move(executed_at: 31.minutes.ago)

      expect(described_class.stale_read?(appointment, starts_at: old_start, ends_at: old_end)).to be(false)
    end

    it 'only counts a move the provider answered OK to' do
      acknowledged_move(status: 'failed')

      expect(described_class.stale_read?(appointment, starts_at: old_start, ends_at: old_end)).to be(false)
    end

    it 'has nothing to hold back for an appointment without a move' do
      expect(described_class.stale_read?(appointment, starts_at: old_start, ends_at: old_end)).to be(false)
    end
  end

  describe 'reception import' do
    let(:service) { Integrations::Medelement::AppointmentImporterService.new(account: account) }
    let(:reception) { { 'RECEPTION_CODE' => 'r-1', 'PATIENT_CODE' => 'p-1', 'ACTIVE' => 1 } }

    def import(starts_at, ends_at)
      service.upsert!(
        resource: resource, contact: contact, reception: reception,
        import_context: { starts_at: starts_at, ends_at: ends_at, specialist_code: 'specialist-1' }
      )
    end

    it 'keeps the accepted move when a cached read still shows the old interval' do
      acknowledged_move

      import(old_start, old_end)

      expect(appointment.reload).to have_attributes(starts_at: new_start, ends_at: new_end)
    end

    it 'follows the provider again after the window' do
      acknowledged_move(executed_at: 2.hours.ago)

      import(old_start, old_end)

      expect(appointment.reload).to have_attributes(starts_at: old_start, ends_at: old_end)
    end

    it 'applies the interval the provider confirmed' do
      acknowledged_move

      import(new_start, new_end)

      expect(appointment.reload).to have_attributes(starts_at: new_start, ends_at: new_end)
    end
  end
end
