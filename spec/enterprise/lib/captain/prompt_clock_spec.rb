# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PromptClock do
  def clock(timezone, now_utc)
    local = Time.iso8601(now_utc).in_time_zone(timezone)
    { now_utc: now_utc, now_local: local.iso8601, timezone: timezone, date_local: local.to_date.iso8601, time_local: local.strftime('%H:%M:%S') }
  end

  describe '.now_line' do
    it 'writes the English weekday, the date, the time, the city and the offset in one line' do
      expect(described_class.now_line(clock('Asia/Almaty', '2026-10-12T18:56:00Z'))).to eq('Monday, 12.10.2026, 23:56, Almaty (UTC+5).')
    end

    it 'moves to the next day with the zone, never writing UTC time' do
      line = described_class.now_line(clock('Asia/Almaty', '2026-10-12T20:30:00Z'))

      expect(line).to eq('Tuesday, 13.10.2026, 01:30, Almaty (UTC+5).')
    end

    it 'names the Kazakhstan, Uzbekistan, Kyrgyzstan and Russia cities and their offsets' do
      now = '2026-10-12T12:00:00Z'
      lines = {
        'Asia/Aqtobe' => 'Aktobe (UTC+5)', 'Asia/Aqtau' => 'Aktau (UTC+5)', 'Asia/Oral' => 'Oral (UTC+5)',
        'Asia/Qyzylorda' => 'Kyzylorda (UTC+5)', 'Asia/Qostanay' => 'Kostanay (UTC+5)', 'Asia/Atyrau' => 'Atyrau (UTC+5)',
        'Asia/Tashkent' => 'Tashkent (UTC+5)', 'Asia/Bishkek' => 'Bishkek (UTC+6)', 'Europe/Moscow' => 'Moscow (UTC+3)'
      }

      lines.each do |zone, expected|
        expect(described_class.now_line(clock(zone, now))).to end_with(", #{expected}.")
      end
    end

    it 'falls back to the zone id for an unlisted city and writes half-hour and negative offsets' do
      expect(described_class.now_line(clock('Asia/Kolkata', '2026-10-12T12:00:00Z'))).to eq('Monday, 12.10.2026, 17:30, Asia/Kolkata (UTC+5:30).')
      expect(described_class.now_line(clock('America/Sao_Paulo', '2026-10-12T12:00:00Z')))
        .to eq('Monday, 12.10.2026, 09:00, America/Sao_Paulo (UTC-3).')
      expect(described_class.now_line(clock('UTC', '2026-10-12T12:00:00Z'))).to eq('Monday, 12.10.2026, 12:00, UTC (UTC+0).')
    end

    it 'takes the local time from now_local when now_utc is missing and accepts string keys' do
      line = described_class.now_line('timezone' => 'Asia/Almaty', 'now_local' => '2026-10-12T23:56:00+05:00')

      expect(line).to eq('Monday, 12.10.2026, 23:56, Almaty (UTC+5).')
    end

    it 'writes nothing when the clock has no usable time or zone' do
      expect(described_class.now_line(nil)).to be_nil
      expect(described_class.now_line({})).to be_nil
      expect(described_class.now_line(timezone: 'UTC')).to be_nil
      expect(described_class.now_line(timezone: 'Not/AZone', now_utc: '2026-10-12T12:00:00Z')).to be_nil
      expect(described_class.now_line(timezone: 'Asia/Almaty', now_utc: 'garbage')).to be_nil
    end
  end

  describe '.reply_window_line' do
    let(:window) do
      { channel: 'official_whatsapp', last_incoming_at: '2026-10-12T10:00:00Z', closes_at: '2026-10-13T10:00:00Z', open_now: true }
    end

    it 'writes one line with the close time in the zone of the run for an open window' do
      expect(described_class.reply_window_line(window, time_zone: 'Asia/Almaty'))
        .to eq('WhatsApp reply window is open until 13.10.2026 15:00; after that only approved templates can be sent.')
    end

    it 'writes a closed window, with or without a close time' do
      closed = 'WhatsApp reply window is closed; only approved templates can be sent.'

      expect(described_class.reply_window_line(window.merge(open_now: false), time_zone: 'Asia/Almaty')).to eq(closed)
      expect(described_class.reply_window_line({ channel: 'official_whatsapp' })).to eq(closed)
    end

    it 'writes nothing for any other channel or an empty window' do
      expect(described_class.reply_window_line(window.merge(channel: 'web'))).to be_nil
      expect(described_class.reply_window_line({})).to be_nil
      expect(described_class.reply_window_line(nil)).to be_nil
    end
  end

  describe '.format_time and .format_date' do
    it 'writes a time in the given zone and a plain date without a time of day' do
      time = Time.utc(2026, 10, 12, 20, 30)

      expect(described_class.format_time(time, 'Asia/Almaty')).to eq('13.10.2026 01:30')
      expect(described_class.format_time(time.in_time_zone('Europe/Moscow'), 'Asia/Almaty')).to eq('13.10.2026 01:30')
      expect(described_class.format_time(Date.new(2026, 10, 13), 'Asia/Almaty')).to eq('13.10.2026')
      expect(described_class.format_date(time, 'Asia/Almaty')).to eq('13.10.2026')
      expect(described_class.format_date(time, 'Europe/Moscow')).to eq('12.10.2026')
    end

    it 'uses the workspace default zone when the zone is missing or unknown' do
      time = Time.utc(2026, 10, 12, 20, 30)

      expect(described_class.format_time(time)).to eq('13.10.2026 01:30')
      expect(described_class.format_time(time, 'Nowhere/Land')).to eq('13.10.2026 01:30')
    end
  end

  describe '.time_value?' do
    it 'accepts times and dates only' do
      expect(described_class.time_value?(Time.current)).to be(true)
      expect(described_class.time_value?(Date.current)).to be(true)
      expect(described_class.time_value?(DateTime.now)).to be(true)
      expect(described_class.time_value?('2026-10-12T12:00:00Z')).to be(false)
      expect(described_class.time_value?(12)).to be(false)
    end
  end

  describe '.zone_for' do
    it 'returns the first usable zone, else the workspace default' do
      expect(described_class.zone_for(nil, '', 'Nope/Zone', 'Europe/Moscow', 'Asia/Almaty').tzinfo.name).to eq('Europe/Moscow')
      expect(described_class.zone_for(nil).tzinfo.name).to eq('Asia/Almaty')
      expect(described_class.zone_for(ActiveSupport::TimeZone['Asia/Tashkent']).tzinfo.name).to eq('Asia/Tashkent')
    end
  end
end
