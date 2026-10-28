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

  it 'includes a specialist linked only by usable appointment history' do
    create(:scheduling_resource_service_stat, account: account, resource: other_resource, service: service_record)

    expect(perform(service_id: service_record.id)[:resources].pluck(:id)).to contain_exactly(resource.id, other_resource.id)
  end

  it 'searches an explicitly requested snapshot specialist without a service link' do
    snapshots = Captain::Playground::SchedulingSnapshots.new(
      'resources' => [{ 'id' => other_resource.id, 'name' => other_resource.name, 'timezone' => 'Asia/Almaty',
                        'slot_duration_min' => 30, 'active' => true, 'service_ids' => [] }],
      'services' => [{ 'id' => service_record.id, 'name' => service_record.name, 'duration_min' => 30, 'active' => true }],
      'appointments' => []
    )

    expect(perform(resource_ids: [other_resource.id], service_id: service_record.id, snapshots: snapshots)[:resources].pluck(:id))
      .to eq([other_resource.id])
  end

  it 'does not use a price row assigned to another account and asks for a specialist instead' do
    foreign_service = create(:scheduling_service, account: account, name: 'Unverified service')
    link = create(:scheduling_service_price, account: account, service: foreign_service, resource: other_resource)
    link.update_columns(account_id: other_account.id) # rubocop:disable Rails/SkipsModelValidations
    expect(Scheduling::ResourceAvailabilityQueryService).not_to receive(:new)

    expect { perform(service_id: foreign_service.id, limit: 1) }
      .to raise_error(described_class::ResourceSelectionRequiredError, described_class::RESOURCE_SELECTION_REQUIRED_ERROR)
  end

  it 'asks for a specialist instead of searching every specialist when no specialist is recorded for the service' do
    unsupported_service = create(:scheduling_service, account: account, name: 'Unsupported service', duration_min: 30)
    expect(Scheduling::ResourceAvailabilityQueryService).not_to receive(:new)

    expect { perform(service_id: unsupported_service.id, limit: 1) }
      .to raise_error(described_class::ResourceSelectionRequiredError, described_class::RESOURCE_SELECTION_REQUIRED_ERROR)
    expect(described_class::ResourceSelectionRequiredError.ancestors).to include(ArgumentError)
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

  it 'searches a requested specialist with a service that has no link to that specialist, unconfirmed' do
    payload = perform(resource_ids: [other_resource.id], service_id: service_record.id, limit: 2)

    expect(payload[:resources].pluck(:id)).to eq([other_resource.id])
    expect(payload[:duration_min]).to eq(30)
    expect(payload[:slots].first).to include(resource_id: other_resource.id, starts_at: '2026-04-20T09:00:00+05:00',
                                             ends_at: '2026-04-20T09:30:00+05:00')
    expect(payload[:slots].pluck(:service_eligibility_status).uniq).to eq(['price_link_unverified'])
    expect(payload).to include(service_link_status: 'price_link_unverified', availability_scope: 'service_unconfirmed',
                               candidate_resource_ids: [other_resource.id])
    expect(payload[:service_match]).to eq(confirmed: false, service_id: nil, resource_id: nil, resource_ids: [])
  end

  it 'labels each requested specialist by its own link when only some of them are linked' do
    payload = perform(resource_ids: [resource.id, other_resource.id], service_id: service_record.id)

    statuses = payload[:slots].to_h { |slot| [slot[:resource_id], slot[:service_eligibility_status]] }
    expect(statuses).to eq(resource.id => 'local_configured', other_resource.id => 'price_link_unverified')
    expect(payload).to include(service_link_status: 'price_link_unverified', availability_scope: 'service_unconfirmed')
  end

  describe 'an account with no service-price links at all' do
    before { Scheduling::ServicePrice.where(account_id: account.id).delete_all }

    it 'searches the requested specialists with the service and its duration' do
      payload = perform(resource_ids: [resource.id, other_resource.id], service_id: service_record.id, limit: 4)

      expect(payload[:resources].pluck(:id)).to contain_exactly(resource.id, other_resource.id)
      expect(payload[:duration_min]).to eq(30)
      expect(payload[:slots].pluck(:resource_id).uniq).to contain_exactly(resource.id, other_resource.id)
      expect(payload[:slots]).to all(include(service_eligibility_status: 'price_link_unverified'))
      expect(payload).to include(service_link_status: 'price_link_unverified', availability_scope: 'service_unconfirmed')
    end

    it 'asks for a specialist when the service is searched without one, and never searches every specialist' do
      expect(Scheduling::ResourceAvailabilityQueryService).not_to receive(:new)

      expect { perform(service_id: service_record.id) }.to raise_error(described_class::ResourceSelectionRequiredError)
    end

    it 'still searches every specialist when no service is requested' do
      payload = perform(limit: 4)

      expect(payload[:resources].pluck(:id)).to contain_exactly(resource.id, other_resource.id)
      expect(payload).to include(service_link_status: 'not_requested', availability_scope: 'generic')
    end
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
      expect(starts(search_between(at(10, 30), at(10, 31), duration_min: 20))).to eq([at(10, 30).iso8601])
    end

    it 'finds no start between two starts of the grid of the specialist' do
      expect(starts(search_between(at(10, 15), at(10, 16), duration_min: 20))).to eq([])
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

    it 'offers the start inside a window shorter than one visit, although its visit ends after the window' do
      payload = search_between(at(10), at(10, 20), service_id: service_record.id)

      expect(starts(payload)).to eq([at(10).iso8601])
      expect(payload[:slots].last[:ends_at]).to eq(at(10, 30).iso8601)
    end

    it 'offers the starts up to the end of a window that holds a visit, whose visit ends after it' do
      payload = search_between(at(9), at(10), duration_min: 45)

      expect(starts(payload)).to eq([at(9).iso8601, at(9, 30).iso8601])
      expect(payload[:slots].last[:ends_at]).to eq(at(10, 15).iso8601)
    end

    it 'does not offer a start at or after the end of the range' do
      expect(starts(search_between(at(9), at(10), service_id: service_record.id))).not_to include(at(10).iso8601)
    end

    it 'does not read the schedule further than the days a range may hold' do
      last_day = time_zone.local(2026, 5, 21, 23, 59, 0)
      from = time_zone.local(2026, 4, 20, 8, 0, 0)

      expect { described_class.new(account: account, from: from, to: last_day, resource_ids: [resource.id]).perform }.not_to raise_error
    end

    it 'counts the limit from the start of the range, so a later hour is reached by moving the range' do
      early = search_between(at(9), at(11), service_id: service_record.id, limit: 2)
      later = search_between(at(10), at(11), service_id: service_record.id, limit: 2)

      expect(starts(early)).to eq([at(9).iso8601, at(9, 30).iso8601])
      expect(starts(later)).to eq([at(10).iso8601, at(10, 30).iso8601])
    end

    # Suggestion eval 26.10, Sezim (Байтурсынова): «последняя запись 19:00», but the schedule showed 19:30 and 19:50, and a draft offered
    # 19:00. A clinic with a last booking time never gets a later start offered.
    it 'offers no start after the last booking time of the clinic, and says which time that is' do
      account.update!(scheduling_last_booking_time: '10:00')

      payload = search_between(at(9), at(11), service_id: service_record.id)

      expect(starts(payload)).to eq([at(9).iso8601, at(9, 30).iso8601, at(10).iso8601])
      expect(payload[:last_booking_time]).to eq('10:00')
      expect(starts(search_between(at(10, 30), at(10, 31), service_id: service_record.id))).to eq([])
    end

    it 'keeps every start without a last booking time, and accepts only an exact time of day as one' do
      expect(starts(search_between(at(9), at(11), service_id: service_record.id)).size).to eq(4)
      expect(perform(resource_ids: [resource.id])).not_to have_key(:last_booking_time)
      expect(account.update(scheduling_last_booking_time: '19:00:00')).to be(false)
      expect(account.reload.update(scheduling_last_booking_time: nil)).to be(true)
    end

    # Suggestion eval 26.10, Sezim (Сыганак): the branch takes its last booking at 13:40 on Saturdays and 18:40 on weekdays, but the
    # Saturday schedule runs to 15:00, and a draft offered 14:40 on a Saturday. One time for the account could not say both.
    context 'with a last booking time per weekday' do
      def saturday(hour, minute = 0)
        time_zone.local(2026, 4, 25, hour, minute, 0)
      end

      before { create(:scheduling_work_rule, account: account, resource: resource, weekday: 6, start_minute: 9 * 60, end_minute: 15 * 60) }

      it 'offers no start after the limit of the weekday of the slot, and keeps the default on the other weekdays' do
        account.update!(scheduling_last_booking_time: '10:00', scheduling_last_booking_time_by_weekday: { 'sat' => '13:40' })

        monday = search_between(at(9), at(11), service_id: service_record.id)
        sat = search_between(saturday(9), saturday(15), service_id: service_record.id)

        expect(starts(monday)).to eq([at(9).iso8601, at(9, 30).iso8601, at(10).iso8601])
        expect(starts(sat).last).to eq(saturday(13, 30).iso8601)
        expect(starts(sat)).not_to include(saturday(14).iso8601, saturday(14, 30).iso8601)
        expect(sat).to include(last_booking_time: '10:00', last_booking_time_by_weekday: { 'sat' => '13:40' })
      end

      it 'limits only the listed weekday when the account has no default, and lets a null weekday go on to its schedule' do
        account.update!(scheduling_last_booking_time_by_weekday: { 'sat' => '12:00', 'mon' => nil })

        expect(starts(search_between(saturday(9), saturday(15), service_id: service_record.id)).last).to eq(saturday(12).iso8601)
        expect(starts(search_between(at(9), at(11), service_id: service_record.id)).size).to eq(4)
        account.update!(scheduling_last_booking_time: '09:30')
        expect(starts(search_between(at(9), at(11), service_id: service_record.id)).size).to eq(4)
        expect(starts(search_between(saturday(9), saturday(15), service_id: service_record.id)).last).to eq(saturday(12).iso8601)
      end

      it 'accepts only a time of day for a weekday of the week' do
        expect(account.update(scheduling_last_booking_time_by_weekday: { 'sat' => '13:40', 'sun' => nil })).to be(true)
        expect(account.update(scheduling_last_booking_time_by_weekday: { 'sat' => '25:00' })).to be(false)
        expect(account.update(scheduling_last_booking_time_by_weekday: { 'saturday' => '13:40' })).to be(false)
        expect(account.update(scheduling_last_booking_time_by_weekday: nil)).to be(true)
      end
    end

    # Suggestion eval 26.10: the answer holds only the starts whose whole visit fits into the working window, so the end of a visit is
    # never after the end of the window.
    it 'never offers a start whose visit would end after the working window' do
      payload = search_between(at(9), at(11), duration_min: 50)

      expect(starts(payload)).to eq([at(9).iso8601, at(9, 30).iso8601, at(10).iso8601])
      expect(payload[:slots].map { |slot| Time.iso8601(slot[:ends_at]) }).to all(be <= at(11))
    end

    it 'returns the named time with a limit of one' do
      expect(starts(search_between(at(10, 30), at(10, 31), service_id: service_record.id, limit: 1))).to eq([at(10, 30).iso8601])
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

    it 'drops a blank value, null and 0 and searches the other specialists' do
      expect(resource_ids_found(['', nil, ' ', 0, '0'])).to contain_exactly(resource.id, other_resource.id)
      expect(resource_ids_found('')).to contain_exactly(resource.id, other_resource.id)
    end

    it 'keeps the numeric ids among the dropped ones' do
      expect(resource_ids_found([resource.id.to_s, '', nil, 0])).to eq([resource.id])
      expect(resource_ids_found([nil, other_resource.id, resource.id.to_s])).to contain_exactly(resource.id, other_resource.id)
      expect(resource_ids_found("#{resource.id}, #{other_resource.id}")).to contain_exactly(resource.id, other_resource.id)
    end

    it 'refuses a value that is not an ID, so a name never widens the search to every specialist' do
      message = 'resource_ids takes specialist IDs from search_scheduling_resources'
      ['abc', 'Dr. Aigerim', -3, '1.5x', 'Aigerim'].each do |value|
        expect { perform(resource_ids: [value]) }.to raise_error(Scheduling::Error, message) do |error|
          expect(error.code).to eq('INVALID_RESOURCE_IDS')
          expect(error.details).to include(reason: 'invalid_resource_ids')
        end
      end
      expect { perform(resource_ids: [resource.id, 'Dr. Aigerim']) }.to raise_error(Scheduling::Error, message)
    end

    it 'still reports a numeric id that is not a specialist of the account' do
      expect { perform(resource_ids: ['', external_resource.id]) }
        .to raise_error(ActiveRecord::RecordNotFound, "Specialists not found: #{external_resource.id}")
    end
  end
end
