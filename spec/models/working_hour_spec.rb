# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WorkingHour, locale: :en do
  context 'when on monday 10am' do
    let(:inbox) { create(:inbox, timezone: 'UTC') }

    before do
      Time.zone = 'UTC'
      inbox
      travel_to '26.10.2020 10:00'.to_datetime
    end

    it 'is considered working hour' do
      expect(inbox.working_hours.today.open_now?).to be true
    end
  end

  context 'when on sunday 1pm' do
    let(:inbox) { create(:inbox, timezone: 'UTC') }

    before do
      Time.zone = 'UTC'
      inbox
      travel_to '01.11.2020 13:00'.to_datetime
    end

    it 'is considered out of office' do
      expect(inbox.working_hours.today.closed_now?).to be true
    end
  end

  context 'when on friday 12:30pm' do
    let(:inbox) { create(:inbox, timezone: 'UTC') }

    before do
      Time.zone = 'UTC'
      inbox
      travel_to '10.09.2021 12:30'.to_datetime
    end

    it 'is considered to be in business hours' do
      expect(inbox.working_hours.today.open_now?).to be true
    end
  end

  context 'when on friday 17:30pm' do
    let(:inbox) { create(:inbox, timezone: 'UTC') }

    before do
      Time.zone = 'UTC'
      inbox
      travel_to '10.09.2021 17:30'.to_datetime
    end

    it 'is considered out of office' do
      expect(inbox.working_hours.today.closed_now?).to be true
    end
  end

  context 'when open_all_day is true' do
    let(:inbox) { create(:inbox) }

    before do
      Time.zone = 'UTC'
      inbox.working_hours.find_by(day_of_week: 5).update(open_all_day: true)
      travel_to '18.02.2022 11:00'.to_datetime
    end

    it 'updates open hour and close hour' do
      expect(inbox.working_hours.today.open_all_day?).to be true
      expect(inbox.working_hours.today.open_hour).to be 0
      expect(inbox.working_hours.today.open_minutes).to be 0
      expect(inbox.working_hours.today.close_hour).to be 23
      expect(inbox.working_hours.today.close_minutes).to be 59
    end
  end

  context 'when open_all_day and closed_all_day true at the same time' do
    let(:inbox) { create(:inbox) }

    before do
      Time.zone = 'UTC'
      inbox.working_hours.find_by(day_of_week: 5).update(open_all_day: true)
      travel_to '18.02.2022 11:00'.to_datetime
    end

    it 'throws validation error' do
      working_hour = inbox.working_hours.find_by(day_of_week: 5)
      working_hour.closed_all_day = true
      expect(working_hour.invalid?).to be true
      expect do
        working_hour.save!
      end.to raise_error(ActiveRecord::RecordInvalid,
                         'Validation failed: open_all_day and closed_all_day cannot be true at the same time')
    end
  end

  context 'when on monday 9am in Sydney timezone' do
    let(:inbox) { create(:inbox) }

    before do
      Time.zone = 'Australia/Sydney'
      inbox.update(timezone: 'Australia/Sydney')
      travel_to '10.10.2022 9:00 AEDT'
    end

    it 'is considered working hour' do
      expect(inbox.working_hours.today.open_now?).to be true
    end
  end
end
