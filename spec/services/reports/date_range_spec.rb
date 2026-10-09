# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reports::DateRange do
  let(:account) { build(:account, reporting_timezone: 'Europe/Berlin') }

  it 'converts inclusive workspace dates into a half-open UTC range across DST' do
    range = described_class.new(
      account: account,
      params: { from_date: '2026-03-29', to_date: '2026-03-29' }
    )

    expect(range.from_at.iso8601).to eq('2026-03-28T23:00:00Z')
    expect(range.until_at.iso8601).to eq('2026-03-29T22:00:00Z')
    expect(range.meta).to include(
      from_date: '2026-03-29',
      to_date: '2026-03-29',
      timezone: 'Europe/Berlin'
    )
  end

  it 'returns an IANA timezone identifier when the account stores a Rails friendly zone' do
    account = build(:account, reporting_timezone: 'Almaty')
    range = described_class.new(
      account: account,
      params: { from_date: '2026-03-29', to_date: '2026-03-29' }
    )

    expect(range.meta[:timezone]).to eq('Asia/Almaty')
    local_start_date = range.from_at.in_time_zone(range.timezone).to_date
    local_end_date = (range.until_at - 1.second).in_time_zone(range.timezone).to_date

    expect(local_start_date).to eq(Date.new(2026, 3, 29))
    expect(local_end_date).to eq(Date.new(2026, 3, 29))
  end

  it 'preserves explicit IANA timezone identifiers in response metadata' do
    account = build(:account, reporting_timezone: 'Asia/Almaty')
    range = described_class.new(account: account)

    expect(range.meta[:timezone]).to eq('Asia/Almaty')
  end

  it 'rejects invalid dates, reversed dates, and ranges wider than 90 days' do
    expect do
      described_class.new(account: account, params: { from_date: '2026-02-30' })
    end.to raise_error(ArgumentError, /valid date/)

    expect do
      described_class.new(account: account, params: { from_date: '2026-04-02', to_date: '2026-04-01' })
    end.to raise_error(ArgumentError, /on or before/)

    expect do
      described_class.new(account: account, params: { from_date: '2026-01-01', to_date: '2026-04-01' })
    end.to raise_error(ArgumentError, /cannot exceed 90 days/)
  end

  it 'rejects an invalid stored reporting timezone instead of silently using another zone' do
    account.reporting_timezone = 'Invalid/Timezone'

    expect { described_class.new(account: account) }
      .to raise_error(ArgumentError, 'Invalid reporting timezone')
  end
end
