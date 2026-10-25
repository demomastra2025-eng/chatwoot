# frozen_string_literal: true

# The time text of the agent prompt. Pure formatting: it reads the runtime clock and reply window that the runner puts in the
# run state and never changes them (other readers use those hashes). All times are written in the zone of the run, never in UTC.
class Captain::PromptClock
  CITIES = {
    'Asia/Almaty' => 'Almaty', 'Asia/Aqtobe' => 'Aktobe', 'Asia/Aqtau' => 'Aktau', 'Asia/Oral' => 'Oral',
    'Asia/Qyzylorda' => 'Kyzylorda', 'Asia/Qostanay' => 'Kostanay', 'Asia/Atyrau' => 'Atyrau',
    'Asia/Tashkent' => 'Tashkent', 'Asia/Bishkek' => 'Bishkek', 'Europe/Moscow' => 'Moscow'
  }.freeze
  DATE_TIME_FORMAT = '%d.%m.%Y %H:%M'
  DATE_FORMAT = '%d.%m.%Y'
  # The weekday, the day, the month name and the ISO date together: a model reads "Monday, 12 October 2026 (2026-10-12)" without
  # counting weekdays from a numeric date.
  LONG_DATE_FORMAT = '%A, %-d %B %Y (%Y-%m-%d)'
  # Before this local hour a patient's "tomorrow" may still mean the day that has already begun.
  NIGHT_ENDS_AT_HOUR = 5
  NIGHT_LINE = 'It is after midnight: a patient\'s "tomorrow" may mean today, %<today>s. ' \
               'For "today" or "tomorrow" offer free slots with the full date and book after the patient picks one.'
  NIGHT_MESSAGE_LINE = 'The patient\'s last message was sent after midnight: their "tomorrow" may mean that day, %<day>s.'
  # The send time of a history message, in front of its text: "[Sat 24.10 09:50]". A few tokens per message tell the model which day
  # a patient's "today", "tomorrow" or "on Monday" was written on (a message of Saturday answered on Monday).
  STAMP_FORMAT = '[%a %d.%m %H:%M]'
  STAMP_PATTERN = /\A\s*\[(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{2}\.\d{2} \d{2}:\d{2}\]\s*/
  MESSAGE_LINE = "Patient's last message was sent %<sent>s, %<time>s (%<ago>s): read its today, tomorrow and weekdays from that day."

  class << self
    # "Monday, 12 October 2026 (2026-10-12), 12:34, Almaty (UTC+5). Tomorrow: Tuesday, 13 October 2026 (2026-10-13)." or nil when
    # the clock holds no usable time.
    def now_line(runtime_clock)
      local, city = local_clock(runtime_clock)
      return if local.blank?

      "#{local.strftime(LONG_DATE_FORMAT)}, #{local.strftime('%H:%M')}, #{city} (#{offset_label(local)}). " \
        "Tomorrow: #{(local + 1.day).strftime(LONG_DATE_FORMAT)}."
    end

    # One more line for the hours after midnight, when "today" and "tomorrow" are ambiguous. It names the date of today, so the
    # model reads "tomorrow" as that date or as the one after it by the patient's words and offers times with the full date; nil
    # at any other time and without a usable clock. When the patient's last message (message_sent_at of the clock) was sent on an
    # earlier day, the hour of that message decides instead, and the line names the day it was sent.
    def night_line(runtime_clock)
      local, = local_clock(runtime_clock)
      return if local.blank?

      sent = message_time(runtime_clock, local.time_zone)
      return format(NIGHT_LINE, today: local.strftime(LONG_DATE_FORMAT)) if (sent.nil? || sent.to_date >= local.to_date) && night?(local)

      format(NIGHT_MESSAGE_LINE, day: sent.strftime(LONG_DATE_FORMAT)) if sent && sent.to_date < local.to_date && night?(sent)
    end

    # "Patient's last message was sent Saturday, 24 October 2026 (2026-10-24), 09:50 (2 days ago): ..." when the message being
    # answered (message_sent_at of the clock) was sent on an earlier day than now; nil when it was sent today or is unknown.
    def message_line(runtime_clock)
      local, = local_clock(runtime_clock)
      return if local.blank?

      sent = message_time(runtime_clock, local.time_zone)
      return if sent.nil? || sent.to_date >= local.to_date

      days = (local.to_date - sent.to_date).to_i
      format(MESSAGE_LINE, sent: sent.strftime(LONG_DATE_FORMAT), time: sent.strftime('%H:%M'), ago: days == 1 ? 'yesterday' : "#{days} days ago")
    end

    # "[Sat 24.10 09:50]": the send time of a message (a time or an ISO 8601 string) in the given zone; nil without a usable time.
    def message_stamp(value, time_zone = nil)
      time = value.is_a?(DateTime) ? value.to_time : parse_time(value)
      time&.in_time_zone(zone_for(time_zone))&.strftime(STAMP_FORMAT)
    end

    # The text without a leading send stamp: one the model copied into its reply, or a stamped history text compared with a stored
    # text. Anything that is not a string is returned as it is.
    def unstamped(text)
      return text unless text.is_a?(String)

      text.sub(STAMP_PATTERN, '')
    end

    # One short line about the official WhatsApp reply window, or nil for every other channel.
    def reply_window_line(reply_window, time_zone: nil)
      window = reply_window.to_h.with_indifferent_access
      return unless window[:channel] == 'official_whatsapp'

      closes_at = parse_time(window[:closes_at])
      if window[:open_now] && closes_at.present?
        "WhatsApp reply window is open until #{format_time(closes_at, time_zone)}; after that only approved templates can be sent."
      else
        'WhatsApp reply window is closed; only approved templates can be sent.'
      end
    end

    # A date and time in the given zone as DD.MM.YYYY HH:MM, never UTC unless the zone itself is UTC. A plain date has no time of day.
    def format_time(value, time_zone = nil)
      return value.strftime(DATE_FORMAT) if value.instance_of?(Date)

      value.in_time_zone(zone_for(time_zone)).strftime(DATE_TIME_FORMAT)
    end

    def format_date(value, time_zone = nil)
      return value.strftime(DATE_FORMAT) if value.instance_of?(Date)

      value.in_time_zone(zone_for(time_zone)).strftime(DATE_FORMAT)
    end

    def time_value?(value)
      value.is_a?(Time) || value.is_a?(DateTime) || value.is_a?(ActiveSupport::TimeWithZone) || value.instance_of?(Date)
    end

    # The first usable zone of the candidates (a zone, an IANA name); the workspace default when none is.
    def zone_for(*candidates)
      candidates.each do |candidate|
        return candidate if candidate.is_a?(ActiveSupport::TimeZone)

        zone = ActiveSupport::TimeZone[candidate.to_s] if candidate.present?
        return zone if zone.present?
      end
      ActiveSupport::TimeZone[Scheduling::Constants::DEFAULT_TIMEZONE]
    end

    # A time, or an ISO 8601 string as the runner stores it; nil for anything else.
    def parse_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return if value.blank? || !value.is_a?(String)

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    private

    # The local time of the run clock and the city to show with it; nil when the clock has no usable zone or time.
    def local_clock(runtime_clock)
      clock = runtime_clock.to_h.with_indifferent_access
      zone_id = clock[:timezone].to_s
      zone = ActiveSupport::TimeZone[zone_id] if zone_id.present?
      time = parse_time(clock[:now_utc]) || parse_time(clock[:now_local])
      return if zone.blank? || time.blank?

      [time.in_time_zone(zone), CITIES[zone_id] || CITIES[zone.tzinfo.name] || zone_id]
    end

    def message_time(runtime_clock, zone)
      parse_time(runtime_clock.to_h.with_indifferent_access[:message_sent_at])&.in_time_zone(zone)
    end

    def night?(time)
      time.hour < NIGHT_ENDS_AT_HOUR
    end

    def offset_label(local)
      seconds = local.utc_offset
      sign = seconds.negative? ? '-' : '+'
      hours, rest = seconds.abs.divmod(3600)
      minutes = rest / 60
      minutes.zero? ? "UTC#{sign}#{hours}" : format('UTC%<sign>s%<hours>d:%<minutes>02d', sign: sign, hours: hours, minutes: minutes)
    end
  end
end
