require 'rails_helper'

RSpec.describe Scheduling::AvailableSlotSearchService do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:time_zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Aigerim', timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:other_resource) { create(:scheduling_resource, account: account, name: 'Dana', timezone: 'Asia/Almaty', slot_duration_min: 20) }
  let(:external_resource) { create(:scheduling_resource, account: other_account, name: 'External', timezone: 'Asia/Almaty') }
  let(:service_record) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 30) }
  let(:from_time) { time_zone.local(2026, 4, 20, 9, 0, 0) }
  let(:to_time) { time_zone.local(2026, 4, 20, 11, 0, 0) }

  before do
    create(:scheduling_work_rule, account: account, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 11 * 60)
    create(:scheduling_work_rule, account: account, resource: other_resource, weekday: 1, start_minute: 9 * 60, end_minute: 11 * 60)
    create(:scheduling_work_rule, account: other_account, resource: external_resource, weekday: 1, start_minute: 9 * 60, end_minute: 11 * 60)
    create(:scheduling_service_price, account: account, service: service_record, resource: resource, active: true)
  end

  def perform(**attributes)
    described_class.new(account: account, from: from_time, to: to_time, **attributes).perform
  end

  it 'searches service-compatible slots with normalized resource metadata and global limiting' do
    payload = perform(resource_ids: [resource.id], service_id: service_record.id, limit: 2)

    expect(payload[:service]).to include(id: service_record.id, duration_min: 30)
    expect(payload[:duration_min]).to eq(30)
    expect(payload[:resources].pluck(:id)).to eq([resource.id])
    expect(payload[:slots].length).to eq(2)
    expect(payload[:slots].first).to include(
      resource_id: resource.id,
      resource_name: 'Aigerim',
      timezone: 'Asia/Almaty',
      starts_at: '2026-04-20T09:00:00+05:00',
      ends_at: '2026-04-20T09:30:00+05:00'
    )
    expect(payload[:total_slots]).to eq(2)
  end

  it 'returns a confirmed service link without an offer eligibility flag' do
    payload = perform(resource_ids: [resource.id], service_id: service_record.id, limit: 1)

    expect(payload).to include(
      availability_scope: 'service_confirmed',
      requested_service_id: service_record.id
    )
    expect(payload).not_to have_key(:customer_offer_eligible)
    expect(payload[:service_match]).to include(
      confirmed: true,
      service_id: service_record.id,
      resource_id: resource.id,
      resource_ids: [resource.id]
    )
  end

  it 'filters by service when no explicit specialists are provided' do
    payload = perform(service_id: service_record.id, limit: 1)

    expect(payload[:resources].pluck(:id)).to eq([resource.id])
    expect(payload[:resources].pluck(:id)).not_to include(other_resource.id, external_resource.id)
    expect(payload[:service][:prices]).to eq([])
  end

  it 'does not use a price row assigned to another account' do
    foreign_service = create(:scheduling_service, account: account, name: 'Unverified service')
    link = create(:scheduling_service_price, account: account, service: foreign_service, resource: other_resource)
    link.update_columns(account_id: other_account.id) # rubocop:disable Rails/SkipsModelValidations

    payload = perform(service_id: foreign_service.id, limit: 1)

    expect(payload[:resources]).to eq([])
    expect(payload[:slots]).to eq([])
  end

  it 'marks service availability as unconfirmed when no specialist offers the service' do
    unsupported_service = create(:scheduling_service, account: account, name: 'Unsupported service', duration_min: 30)
    expect(Scheduling::ResourceAvailabilityQueryService).not_to receive(:new)

    payload = perform(service_id: unsupported_service.id, limit: 1)

    expect(payload).to include(
      availability_scope: 'service_unconfirmed',
      requested_service_id: unsupported_service.id
    )
    expect(payload[:service_match]).to eq(confirmed: false, service_id: nil, resource_id: nil, resource_ids: [])
    expect(payload[:slots]).to be_empty
  end

  it 'treats non-positive and blank service ids as an omitted filter' do
    [nil, 0, -1, ''].each do |service_id|
      payload = perform(service_id: service_id, limit: 1)

      expect(payload[:service]).to be_nil
      expect(payload[:resources].pluck(:id)).to contain_exactly(resource.id, other_resource.id)
      expect(payload).to include(
        availability_scope: 'generic',
        requested_service_id: nil
      )
      expect(payload[:service_match]).to eq(confirmed: false, service_id: nil, resource_id: nil, resource_ids: [])
    end
  end

  it 'raises when a requested specialist is outside the account or unavailable for scheduling' do
    expect do
      perform(resource_ids: [external_resource.id])
    end.to raise_error(ActiveRecord::RecordNotFound, "Specialists not found: #{external_resource.id}")
  end

  it 'raises when the requested specialist cannot perform the requested service' do
    expect(Scheduling::ResourceAvailabilityQueryService).not_to receive(:new)

    expect do
      perform(resource_ids: [other_resource.id],
              service_id: service_record.id)
    end.to raise_error(ArgumentError, 'Service is not available for the requested specialists')
  end

  it 'rejects reversed ranges and oversized ranges' do
    expect do
      described_class.new(account: account, from: to_time, to: from_time).perform
    end.to raise_error(ArgumentError, 'to must be greater than from')

    expect do
      described_class.new(account: account, from: from_time, to: from_time + 32.days).perform
    end.to raise_error(ArgumentError, 'Date range must be 31 days or less')
  end

  describe 'the end of the range is the latest start' do
    def at(hour, minute = 0)
      time_zone.local(2026, 4, 20, hour, minute, 0)
    end

    def search_between(from, to, **attributes)
      described_class.new(account: account, from: from, to: to, resource_ids: [resource.id], **attributes).perform
    end

    def starts(payload)
      payload[:slots].pluck(:starts_at)
    end

    it 'finds a free time checked with a one-minute window' do
      payload = search_between(at(10), at(10, 1), service_id: service_record.id)

      expect(starts(payload)).to eq([at(10).iso8601])
      expect(payload[:slots].first[:ends_at]).to eq(at(10, 30).iso8601)
      expect(payload[:total_slots]).to eq(1)
    end

    it 'finds a free time that is not on the hour' do
      expect(starts(search_between(at(10, 15), at(10, 16), duration_min: 20))).to eq([at(10, 15).iso8601])
    end

    it 'accepts a range whose end equals its start as an exact-time check' do
      expect(starts(search_between(at(10), at(10), service_id: service_record.id))).to eq([at(10).iso8601])
    end

    it 'reports no slot when the exact time is taken instead of offering a neighbouring start' do
      create(:scheduling_appointment, account: account, resource: resource, service: service_record,
                                      starts_at: at(10), ends_at: at(10, 30), duration_min: 30)

      payload = search_between(at(10), at(10, 1), service_id: service_record.id)

      expect(payload[:slots]).to eq([])
      expect(payload[:total_slots]).to eq(0)
    end

    it 'uses a window shorter than one visit to find the visit that starts at its beginning' do
      payload = search_between(at(10), at(10, 20), service_id: service_record.id)

      expect(starts(payload)).to eq([at(10).iso8601])
    end

    it 'keeps a window that holds a visit as it was: every visit ends before the end of the range' do
      payload = search_between(at(9), at(10), service_id: service_record.id)

      expect(starts(payload).first).to eq(at(9).iso8601)
      expect(starts(payload).last).to eq(at(9, 30).iso8601)
    end

    it 'counts the limit from the start of the range, so a later hour is reached by moving the range' do
      early = search_between(at(9), at(11), service_id: service_record.id, limit: 2)
      later = search_between(at(10), at(11), service_id: service_record.id, limit: 2)

      expect(starts(early)).to eq([at(9).iso8601, at(9, 5).iso8601])
      expect(starts(later)).to eq([at(10).iso8601, at(10, 5).iso8601])
    end

    it 'returns the named time with a limit of one' do
      expect(starts(search_between(at(10, 25), at(10, 26), service_id: service_record.id, limit: 1))).to eq([at(10, 25).iso8601])
    end

    it 'reads each specialist with the length of its own visit' do
      payload = described_class.new(account: account, from: at(10), to: at(10, 1), resource_ids: [resource.id, other_resource.id]).perform

      expect(payload[:slots].map { |slot| [slot[:resource_id], slot[:ends_at]] }).to contain_exactly(
        [resource.id, at(10, 30).iso8601], [other_resource.id, at(10, 20).iso8601]
      )
    end

    it 'rejects a range that ends before it starts' do
      expect { search_between(at(10), at(9, 59)) }.to raise_error(ArgumentError, 'to must be greater than from')
    end
  end

  describe 'specialist ids' do
    def resource_ids_found(resource_ids)
      perform(resource_ids: resource_ids, limit: 1)[:resources].pluck(:id)
    end

    it 'ignores blank and non-numeric ids and searches the other specialists' do
      expect(resource_ids_found(['', nil, ' ', 'abc', 'Dr. Aigerim', 0, -3])).to contain_exactly(resource.id, other_resource.id)
      expect(resource_ids_found('')).to contain_exactly(resource.id, other_resource.id)
    end

    it 'keeps the numeric ids among the ignored ones' do
      expect(resource_ids_found([resource.id.to_s, '', 'abc'])).to eq([resource.id])
      expect(resource_ids_found([nil, other_resource.id, resource.id.to_s])).to contain_exactly(resource.id, other_resource.id)
      expect(resource_ids_found("#{resource.id}, #{other_resource.id}")).to contain_exactly(resource.id, other_resource.id)
    end

    it 'still reports a numeric id that is not a specialist of the account' do
      expect { perform(resource_ids: ['', external_resource.id]) }
        .to raise_error(ActiveRecord::RecordNotFound, "Specialists not found: #{external_resource.id}")
    end
  end
end
