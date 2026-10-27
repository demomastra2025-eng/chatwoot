require 'rails_helper'

RSpec.describe Scheduling::TemplateFieldFillStats do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:field_id) { 'appointment.service_name_snapshot' }

  it 'counts blank rendered values only for upcoming scheduled and confirmed visits' do
    create(:scheduling_appointment, account: account, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes,
                                    service_name_snapshot: nil)
    create(:scheduling_appointment, account: account, status: 'confirmed', starts_at: 3.days.from_now,
                                    ends_at: 3.days.from_now + 30.minutes, service_name_snapshot: 'Consultation')
    create(:scheduling_appointment, account: account, status: 'cancelled', starts_at: 4.days.from_now,
                                    ends_at: 4.days.from_now + 30.minutes, service_name_snapshot: nil)
    create(:scheduling_appointment, account: account, starts_at: 2.days.ago, ends_at: 2.days.ago + 30.minutes,
                                    service_name_snapshot: nil)

    expect(described_class.new(account: account, field_ids: [field_id]).perform).to contain_exactly(
      field_id: field_id, total: 2, empty: 1, share: 0.5, blocking: true
    )
  end

  it 'does not block an account with no upcoming visits' do
    expect(described_class.new(account: account, field_ids: [field_id]).perform.first).to include(
      total: 0, empty: 0, share: 0.0, blocking: false
    )
  end

  it 'blocks at the documented ten percent boundary' do
    10.times do |index|
      starts_at = (index + 2).days.from_now
      create(:scheduling_appointment, account: account, starts_at: starts_at,
                                      ends_at: starts_at + 30.minutes,
                                      service_name_snapshot: index.zero? ? nil : 'Consultation')
    end

    expect(described_class.new(account: account, field_ids: [field_id]).perform.first).to include(
      total: 10, empty: 1, share: 0.1, blocking: true
    )
  end
end
