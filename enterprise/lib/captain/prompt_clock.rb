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
    # at any other time and without a usable clock.
    def night_line(runtime_clock)
      local, = local_clock(runtime_clock)
      return unless local.present? && local.hour < NIGHT_ENDS_AT_HOUR

      format(NIGHT_LINE, today: local.strftime(LONG_DATE_FORMAT))
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

    def offset_label(local)
      seconds = local.utc_offset
      sign = seconds.negative? ? '-' : '+'
      hours, rest = seconds.abs.divmod(3600)
      minutes = rest / 60
      minutes.zero? ? "UTC#{sign}#{hours}" : format('UTC%<sign>s%<hours>d:%<minutes>02d', sign: sign, hours: hours, minutes: minutes)
    end
  end
end
