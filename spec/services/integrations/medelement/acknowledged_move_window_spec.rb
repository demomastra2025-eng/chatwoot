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
                                    custom_attributes: { 'medelement_reception_code' => 'r-1', 'medelement_provider_operation' => 'move_reception' })
  end

  def acknowledged_move(executed_at: Time.current, status: 'succeeded', from: [old_start, old_end], to: [new_start, new_end])
    Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: contact, operation: 'move_reception', status: status,
      idempotency_key: "move-#{SecureRandom.hex(4)}", provider_reception_code: 'r-1', company_cabinet_code: 'cabinet-1',
      desired_starts_at: to.first, desired_ends_at: to.last, executed_at: executed_at,
      execution_state: { 'request_snapshot' => { 'reception' => {
        'source_starts_at' => from.first.iso8601(6), 'source_ends_at' => from.last.iso8601(6),
        'destination_starts_at' => to.first.iso8601(6), 'destination_ends_at' => to.last.iso8601(6)
      } } }
    )
  end

  def acknowledged_create(executed_at: Time.current, status: 'succeeded')
    Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: contact, operation: 'create_reception', status: status,
      idempotency_key: "create-#{SecureRandom.hex(4)}", provider_reception_code: 'r-1', company_cabinet_code: 'cabinet-1',
      desired_starts_at: new_start, desired_ends_at: new_end, executed_at: executed_at
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

    it 'looks nothing up when the provider agrees with the calendar' do
      acknowledged_move
      allow(Integrations::Medelement::ProviderCommand).to receive(:where).and_call_original

      expect(described_class.stale_read?(appointment, starts_at: new_start, ends_at: new_end)).to be(false)
      expect(Integrations::Medelement::ProviderCommand).not_to have_received(:where)
    end

    it 'has nothing to hold back for an appointment without a move' do
      expect(described_class.stale_read?(appointment, starts_at: old_start, ends_at: old_end)).to be(false)
    end

    # The cancellation sent after a move projects its own operation onto the appointment before its command runs.
    it 'still recognises the pre-move interval once another operation was projected onto the appointment' do
      acknowledged_move
      appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_provider_operation' => 'remove_reception'))

      expect(described_class.stale_read?(appointment, starts_at: old_start, ends_at: old_end)).to be(true)
    end

    it 'recognises the pre-move interval of an appointment that never carried a provider operation' do
      acknowledged_move
      appointment.update!(custom_attributes: appointment.custom_attributes.except('medelement_provider_operation'))

      expect(described_class.stale_read?(appointment, starts_at: old_start, ends_at: old_end)).to be(true)
    end

    context 'when the reception was moved twice inside the window' do
      let(:first_start) { old_start - 2.hours }
      let(:first_end) { old_end - 2.hours }

      before do
        acknowledged_move(executed_at: 2.minutes.ago, from: [first_start, first_end], to: [old_start, old_end])
        acknowledged_move(executed_at: 1.minute.ago)
      end

      it 'recognises the interval before the first move' do
        expect(described_class.stale_read?(appointment, starts_at: first_start, ends_at: first_end)).to be(true)
      end

      it 'recognises the interval between the two moves' do
        expect(described_class.stale_read?(appointment, starts_at: old_start, ends_at: old_end)).to be(true)
      end

      it 'does not hold back the latest interval' do
        expect(described_class.stale_read?(appointment, starts_at: new_start, ends_at: new_end)).to be(false)
      end

      it 'does not hold back a third interval' do
        expect(described_class.stale_read?(appointment, starts_at: new_start + 3.hours, ends_at: new_end + 3.hours)).to be(false)
      end
    end

    it 'does not hold back the interval a reception moved away and back to' do
      acknowledged_move(executed_at: 2.minutes.ago)
      acknowledged_move(executed_at: 1.minute.ago, from: [new_start, new_end], to: [old_start, old_end])
      appointment.update!(starts_at: old_start, ends_at: old_end)

      expect(described_class.stale_read?(appointment, starts_at: old_start, ends_at: old_end)).to be(false)
      expect(described_class.stale_read?(appointment, starts_at: new_start, ends_at: new_end)).to be(true)
    end
  end

  describe '.latest_acknowledged_write' do
    it 'returns the latest create or move the provider answered OK to inside the window' do
      acknowledged_create(executed_at: 5.minutes.ago)
      move = acknowledged_move(executed_at: 1.minute.ago)

      expect(described_class.latest_acknowledged_write(appointment)).to eq(move)
    end

    it 'returns a create' do
      create_command = acknowledged_create

      expect(described_class.latest_acknowledged_write(appointment)).to eq(create_command)
    end

    it 'ignores a write older than the window and a write the provider did not accept' do
      acknowledged_create(executed_at: 31.minutes.ago)
      acknowledged_move(status: 'failed')

      expect(described_class.latest_acknowledged_write(appointment)).to be_nil
    end

    it 'has nothing for a missing appointment' do
      expect(described_class.latest_acknowledged_write(nil)).to be_nil
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

    it 'keeps the accepted move when the cancellation after it already projected its own operation' do
      acknowledged_move
      appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_provider_operation' => 'remove_reception'))

      import(old_start, old_end)

      expect(appointment.reload).to have_attributes(starts_at: new_start, ends_at: new_end)
    end

    it 'keeps the latest of two accepted moves when a cached read still shows the very first interval' do
      acknowledged_move(executed_at: 2.minutes.ago, from: [old_start - 2.hours, old_end - 2.hours], to: [old_start, old_end])
      acknowledged_move(executed_at: 1.minute.ago)

      import(old_start - 2.hours, old_end - 2.hours)

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
