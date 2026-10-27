# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PromptClock do
  def clock(timezone, now_utc)
    local = Time.iso8601(now_utc).in_time_zone(timezone)
    { now_utc: now_utc, now_local: local.iso8601, timezone: timezone, date_local: local.to_date.iso8601, time_local: local.strftime('%H:%M:%S') }
  end

  describe '.now_line' do
    it 'writes the weekday, the day, the month name and the ISO date, the time, the city, the offset and tomorrow in one line' do
      expect(described_class.now_line(clock('Asia/Almaty', '2026-10-12T07:34:00Z'))).to eq(
        'Monday, 12 October 2026 (2026-10-12), 12:34, Almaty (UTC+5). Tomorrow: Tuesday, 13 October 2026 (2026-10-13).'
      )
    end

    it 'moves to the next day with the zone, never writing UTC time' do
      line = described_class.now_line(clock('Asia/Almaty', '2026-10-12T20:30:00Z'))

      expect(line).to eq('Tuesday, 13 October 2026 (2026-10-13), 01:30, Almaty (UTC+5). Tomorrow: Wednesday, 14 October 2026 (2026-10-14).')
    end

    it 'writes a one-digit day without a leading zero and crosses the end of a month and of a year' do
      expect(described_class.now_line(clock('Asia/Almaty', '2026-10-05T07:00:00Z')))
        .to start_with('Monday, 5 October 2026 (2026-10-05), 12:00, Almaty (UTC+5). Tomorrow: Tuesday, 6 October 2026 (2026-10-06).')
      expect(described_class.now_line(clock('Asia/Almaty', '2026-10-31T07:00:00Z')))
        .to end_with('Tomorrow: Sunday, 1 November 2026 (2026-11-01).')
      expect(described_class.now_line(clock('Asia/Almaty', '2026-12-31T07:00:00Z')))
        .to end_with('Tomorrow: Friday, 1 January 2027 (2027-01-01).')
    end

    it 'names the Kazakhstan, Uzbekistan, Kyrgyzstan and Russia cities and their offsets' do
      now = '2026-10-12T12:00:00Z'
      lines = {
        'Asia/Aqtobe' => 'Aktobe (UTC+5)', 'Asia/Aqtau' => 'Aktau (UTC+5)', 'Asia/Oral' => 'Oral (UTC+5)',
        'Asia/Qyzylorda' => 'Kyzylorda (UTC+5)', 'Asia/Qostanay' => 'Kostanay (UTC+5)', 'Asia/Atyrau' => 'Atyrau (UTC+5)',
        'Asia/Tashkent' => 'Tashkent (UTC+5)', 'Asia/Bishkek' => 'Bishkek (UTC+6)', 'Europe/Moscow' => 'Moscow (UTC+3)'
      }

      lines.each do |zone, expected|
        expect(described_class.now_line(clock(zone, now))).to include(", #{expected}. Tomorrow: ")
      end
    end

    it 'falls back to the zone id for an unlisted city and writes half-hour and negative offsets' do
      expect(described_class.now_line(clock('Asia/Kolkata', '2026-10-12T12:00:00Z')))
        .to start_with('Monday, 12 October 2026 (2026-10-12), 17:30, Asia/Kolkata (UTC+5:30). Tomorrow: ')
      expect(described_class.now_line(clock('America/Sao_Paulo', '2026-10-12T12:00:00Z')))
        .to start_with('Monday, 12 October 2026 (2026-10-12), 09:00, America/Sao_Paulo (UTC-3). Tomorrow: ')
      expect(described_class.now_line(clock('UTC', '2026-10-12T12:00:00Z')))
        .to start_with('Monday, 12 October 2026 (2026-10-12), 12:00, UTC (UTC+0). Tomorrow: ')
    end

    it 'takes the local time from now_local when now_utc is missing and accepts string keys' do
      line = described_class.now_line('timezone' => 'Asia/Almaty', 'now_local' => '2026-10-12T23:56:00+05:00')

      expect(line).to eq('Monday, 12 October 2026 (2026-10-12), 23:56, Almaty (UTC+5). Tomorrow: Tuesday, 13 October 2026 (2026-10-13).')
    end

    it 'writes nothing when the clock has no usable time or zone' do
      expect(described_class.now_line(nil)).to be_nil
      expect(described_class.now_line({})).to be_nil
      expect(described_class.now_line(timezone: 'UTC')).to be_nil
      expect(described_class.now_line(timezone: 'Not/AZone', now_utc: '2026-10-12T12:00:00Z')).to be_nil
      expect(described_class.now_line(timezone: 'Asia/Almaty', now_utc: 'garbage')).to be_nil
    end
  end

  describe '.night_line' do
    let(:night) do
      'It is after midnight: a patient\'s "tomorrow" may mean today, Tuesday, 13 October 2026 (2026-10-13). ' \
        'For "today" or "tomorrow" offer free slots with the full date and book after the patient picks one.'
    end

    it 'is written between 00:00 and 05:00 of the local time and at no other hour' do
      expect(described_class.night_line(clock('Asia/Almaty', '2026-10-12T19:00:00Z'))).to eq(night)
      expect(described_class.night_line(clock('Asia/Almaty', '2026-10-12T19:15:00Z'))).to eq(night)
      expect(described_class.night_line(clock('Asia/Almaty', '2026-10-12T23:59:00Z'))).to eq(night)
      expect(described_class.night_line(clock('Asia/Almaty', '2026-10-13T00:00:00Z'))).to be_nil
      expect(described_class.night_line(clock('Asia/Almaty', '2026-10-12T18:59:00Z'))).to be_nil
      expect(described_class.night_line(clock('Asia/Almaty', '2026-10-12T07:34:00Z'))).to be_nil
    end

    it 'names the date that has already begun, not the day the Now line calls Tomorrow' do
      line = described_class.night_line(clock('Asia/Almaty', '2026-10-12T19:15:00Z'))

      expect(line).to include('2026-10-13')
      expect(line).not_to include('2026-10-14', 'coming day')
    end

    it 'reads the hour in the zone of the run, not in UTC' do
      expect(described_class.night_line(clock('Europe/Moscow', '2026-10-12T22:00:00Z'))).to eq(night)
      expect(described_class.night_line(clock('Europe/Moscow', '2026-10-12T02:00:00Z'))).to be_nil
    end

    it 'writes nothing when the clock has no usable time or zone' do
      expect(described_class.night_line(nil)).to be_nil
      expect(described_class.night_line(timezone: 'Not/AZone', now_utc: '2026-10-12T20:00:00Z')).to be_nil
      expect(described_class.night_line(timezone: 'Asia/Almaty', now_utc: 'garbage')).to be_nil
    end
  end

  # A patient wrote on Saturday 24 October (Almaty); the operator asks for a suggestion on Monday 26 October.
  describe 'the time of the message being answered' do
    let(:monday) { clock('Asia/Almaty', '2026-10-26T04:00:00Z') }

    it 'names the day and the time of a message sent on an earlier day, and how long ago' do
      line = described_class.message_line(monday.merge(message_sent_at: '2026-10-24T04:50:00Z'))

      expect(line).to start_with("Patient's last message was sent Saturday, 24 October 2026 (2026-10-24), 09:50 (2 days ago). ")
      expect(described_class.message_line(monday.merge(message_sent_at: '2026-10-25T15:00:00Z'))).to include('(yesterday)')
    end

    # Suggestion eval 27.10 (c77-1167712, c78-1194483): «завтра 09:00» written the day before was offered for the day after the
    # clock's tomorrow. The relative days of the message are written out as dates, so the model reads them instead of counting.
    it 'writes out today, tomorrow and the day after tomorrow of the day the message was sent, with the words patients write' do
      line = described_class.message_line(monday.merge(message_sent_at: '2026-10-24T04:50:00Z'))

      expect(line).to eq(
        "Patient's last message was sent Saturday, 24 October 2026 (2026-10-24), 09:50 (2 days ago). " \
        'Read its relative days from that day, never from the clock above: ' \
        'today (сегодня, бүгін) = Saturday, 24 October 2026 (2026-10-24), ' \
        'tomorrow (завтра, ертең) = Sunday, 25 October 2026 (2026-10-25), ' \
        'the day after tomorrow (послезавтра) = Monday, 26 October 2026 (2026-10-26). ' \
        'By the clock above: 2026-10-24 has passed (2 days ago), 2026-10-25 has passed (yesterday), 2026-10-26 is today, ' \
        '2026-10-27 is tomorrow. ' \
        'In your reply name such a day by its date, and call a day today or tomorrow only when it is today or tomorrow by the clock above.'
      )
    end

    # Suggestion eval 27.10 (c77-1167712): the patient wrote «завтра 09:00» on Tuesday 27 October and the operator answered on Wednesday
    # 28 October; the model searched Thursday, the clock's tomorrow. The line says that the patient's tomorrow is today by the clock.
    it 'says where each of the three days stands by the clock, so the patient\'s tomorrow of yesterday is read as today' do
      wednesday = clock('Asia/Almaty', '2026-10-28T02:01:37Z')
      line = described_class.message_line(wednesday.merge(message_sent_at: '2026-10-27T03:30:00Z'))

      expect(line).to include('sent Tuesday, 27 October 2026 (2026-10-27), 08:30 (yesterday)',
                              'tomorrow (завтра, ертең) = Wednesday, 28 October 2026 (2026-10-28)',
                              'By the clock above: 2026-10-27 has passed (yesterday), 2026-10-28 is today, 2026-10-29 is tomorrow.',
                              'In your reply name such a day by its date')
    end

    # Suggestion eval 27.10 (c77-1167712): the model read the «ертең» of yesterday's message as the "Tomorrow:" of the clock line, though the
    # message line named the day. With a message of an earlier day the clock line has no "Tomorrow:", and the message line says which
    # day is the clock's tomorrow.
    it 'leaves the "Tomorrow" out of the clock line when the message being answered was sent on an earlier day' do
      wednesday = clock('Asia/Almaty', '2026-10-28T02:01:37Z')

      expect(described_class.now_line(wednesday.merge(message_sent_at: '2026-10-27T03:30:00Z')))
        .to eq('Wednesday, 28 October 2026 (2026-10-28), 07:01, Almaty (UTC+5).')
      expect(described_class.now_line(wednesday.merge(message_sent_at: '2026-10-27T03:30:00Z'))).not_to include('Tomorrow')
      expect(described_class.now_line(wednesday.merge(message_sent_at: '2026-10-28T01:30:00Z')))
        .to eq('Wednesday, 28 October 2026 (2026-10-28), 07:01, Almaty (UTC+5). Tomorrow: Thursday, 29 October 2026 (2026-10-29).')
      expect(described_class.now_line(wednesday)).to end_with('Tomorrow: Thursday, 29 October 2026 (2026-10-29).')
    end

    # Suggestion eval 27.10 (c78-1186952): the patient's «сегодня» of yesterday was named «Сегодня, 29 октября» in the reply.
    it 'says that the patient\'s today of an earlier day has passed, and when a day is further ahead' do
      friday = clock('Asia/Almaty', '2026-10-30T08:51:00Z')

      expect(described_class.message_line(friday.merge(message_sent_at: '2026-10-29T08:33:00Z')))
        .to include('By the clock above: 2026-10-29 has passed (yesterday), 2026-10-30 is today, 2026-10-31 is tomorrow.')
      expect(described_class.message_line(friday.merge(message_sent_at: '2026-10-23T08:33:00Z')))
        .to include('By the clock above: 2026-10-23 has passed (7 days ago), 2026-10-24 has passed (6 days ago), ' \
                    '2026-10-25 has passed (5 days ago), 2026-10-30 is today, 2026-10-31 is tomorrow.')
      future = clock('Asia/Almaty', '2026-10-24T08:00:00Z').merge(message_sent_at: '2026-10-23T08:33:00Z')
      expect(described_class.message_line(future)).to include('2026-10-23 has passed (yesterday), 2026-10-24 is today, 2026-10-25 is tomorrow.')
    end

    it 'writes the dates of the message across the end of a month, not those of the clock' do
      line = described_class.message_line(clock('Asia/Almaty', '2026-11-03T07:00:00Z').merge(message_sent_at: '2026-10-30T13:00:00Z'))

      expect(line).to include('sent Friday, 30 October 2026 (2026-10-30), 18:00 (4 days ago)',
                              'today (сегодня, бүгін) = Friday, 30 October 2026 (2026-10-30)',
                              'tomorrow (завтра, ертең) = Saturday, 31 October 2026 (2026-10-31)',
                              'the day after tomorrow (послезавтра) = Sunday, 1 November 2026 (2026-11-01)')
    end

    it 'writes nothing for a message of today, a missing time or a clock without a zone' do
      expect(described_class.message_line(monday.merge(message_sent_at: '2026-10-25T19:30:00Z'))).to be_nil
      expect(described_class.message_line(monday)).to be_nil
      expect(described_class.message_line(message_sent_at: '2026-10-24T04:50:00Z')).to be_nil
    end

    # Review of quality-fixes-1 (M7): a message sent at 01:30 and answered two days later got the line that said tomorrow was the next
    # day and the night line that said it might be the same day. The one line of the message gives both readings.
    it 'gives both readings of tomorrow, in the one line, for a message of an earlier day that was sent after midnight' do
      sent_at_night = monday.merge(message_sent_at: '2026-10-23T20:30:00Z')

      line = described_class.message_line(sent_at_night)

      expect(line).to start_with("Patient's last message was sent Saturday, 24 October 2026 (2026-10-24), 01:30 (2 days ago), after midnight. ")
      expect(line).to include(
        'today (сегодня, бүгін) = Saturday, 24 October 2026 (2026-10-24)',
        'tomorrow (завтра, ертең) = Saturday, 24 October 2026 (2026-10-24) or Sunday, 25 October 2026 (2026-10-25) ' \
        '(after midnight "tomorrow" may mean the same day)',
        'the day after tomorrow (послезавтра) = Sunday, 25 October 2026 (2026-10-25) or Monday, 26 October 2026 (2026-10-26)',
        'offer free slots with the full date and book after the patient picks one'
      )
      expect(described_class.night_line(sent_at_night)).to be_nil
    end

    it 'leaves the night line to the clock when the message is of an earlier day and the clock is in the night, and to the message of today' do
      monday_night = clock('Asia/Almaty', '2026-10-25T20:30:00Z')

      expect(described_class.night_line(monday.merge(message_sent_at: '2026-10-24T04:50:00Z'))).to be_nil
      expect(described_class.night_line(monday_night.merge(message_sent_at: '2026-10-25T17:50:00Z'))).to be_nil
      expect(described_class.night_line(monday_night.merge(message_sent_at: '2026-10-25T20:20:00Z')))
        .to start_with('It is after midnight: a patient\'s "tomorrow" may mean today, Monday, 26 October 2026 (2026-10-26).')
      expect(described_class.message_line(monday.merge(message_sent_at: '2026-10-24T04:50:00Z'))).not_to include('after midnight')
    end

    # A patient writes at 01:30 on Monday and the operator asks for a suggestion at 09:00 the same day: no other line names the time
    # of that message (it is of today), and its "tomorrow" may mean Monday.
    it 'reads the night of a message of the same day that is answered in the morning' do
      monday_night_message = monday.merge(message_sent_at: '2026-10-25T20:30:00Z')

      expect(described_class.night_line(monday_night_message)).to eq(
        'The patient\'s last message was sent after midnight, at 01:30: their "tomorrow" may mean that day, ' \
        'Monday, 26 October 2026 (2026-10-26).'
      )
      expect(described_class.message_line(monday_night_message)).to be_nil
      expect(described_class.night_line(monday.merge(message_sent_at: '2026-10-26T03:50:00Z'))).to be_nil
      expect(described_class.night_line(monday.merge(message_sent_at: '2026-10-26T20:30:00Z'))).to be_nil
    end
  end

  describe '.message_stamp and .unstamped' do
    it 'writes the weekday, the day, the month and the time of a message in the given zone' do
      expect(described_class.message_stamp(Time.utc(2026, 10, 24, 4, 50), 'Asia/Almaty')).to eq('[Sat 24.10 09:50]')
      expect(described_class.message_stamp('2026-10-25T20:30:00Z', 'Asia/Almaty')).to eq('[Mon 26.10 01:30]')
      expect(described_class.message_stamp(Time.utc(2026, 10, 24, 4, 50).in_time_zone('Asia/Almaty'), 'Europe/Moscow')).to eq('[Sat 24.10 07:50]')
      expect(described_class.message_stamp(nil, 'Asia/Almaty')).to be_nil
      expect(described_class.message_stamp('garbage', 'Asia/Almaty')).to be_nil
    end

    it 'removes a leading stamp only' do
      expect(described_class.unstamped('[Sat 24.10 09:50] Можно завтра?')).to eq('Можно завтра?')
      expect(described_class.unstamped('  [Mon 26.10 01:30]Здравствуйте')).to eq('Здравствуйте')
      expect(described_class.unstamped('Запись [Sat 24.10 09:50] осталась')).to eq('Запись [Sat 24.10 09:50] осталась')
      expect(described_class.unstamped('[24.10 09:50] текст')).to eq('[24.10 09:50] текст')
      expect(described_class.unstamped(nil)).to be_nil
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
