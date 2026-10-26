# frozen_string_literal: true

# The compact answer of search_available_slots for the patient-facing agent. The model re-reads every tool result on every later
# step of a run, so the answer holds what it needs to offer a time and to book it: per specialist and day a few start times spread
# over the day and how many more there are. A slot is never repeated with the specialist's name, the timezone and the cabinet, and
# the service and specialist cards are not attached. Staff and Copilot keep the full payload; this module is for the agent scope.
#
#   { service_id: 12, duration_min: 30, total: 41,
#     days: [{ resource_id: 5, name: 'Dr A', date: '2026-04-20', times: ['09:00', '11:00', '13:00', '15:00', '17:30'], more: 13 }] }
#
# A time is the clinic's clock in the specialist's timezone; the booking takes date + "T" + time as the local start.
module Captain::Tools::Agent::SlotsPayload
  # At most this many start times per specialist and day: more would only be read again on every step.
  TIMES_PER_DAY = 5
  # How many specialist-days an answer lists when the agent gives no limit, and at most.
  DEFAULT_DAYS = 10
  MAX_DAYS = 31
  # After an empty range: the specialist-days of the nearest free time.
  NEXT_AVAILABLE_DAYS = 3
  DEGRADED_NOTE = 'The MedElement schedule could not be checked, so it is not known whether there is free time. ' \
                  'Do not tell the patient that there is none. A price from search_scheduling_services does not depend on the ' \
                  'schedule: give it.'

  module_function

  # payload: the result of the slot search holding every free start of the range (see Scheduling::CompleteSlotSearchService).
  def answer(payload, days_limit: nil)
    slots = Array(payload[:slots])
    days = day_entries(slots)
    listed = days.first(days_count(days_limit))
    duration = shared_duration(slots, payload)
    {
      service_id: payload[:requested_service_id],
      duration_min: duration,
      total: slots.size,
      days: listed.map { |day| duration ? day.except(:duration_min) : day },
      more_days: (days.size - listed.size if days.size > listed.size)
    }.merge(degraded(payload)).compact
  end

  # One entry per specialist and local day, in the order of the days: { resource_id, name, date, times, more }. The times are the
  # starts "HH:MM" of the specialist's clock, at most TIMES_PER_DAY of them spread over the day; more counts the others.
  def day_entries(slots)
    rows = slots.map { |slot| row(slot) }
    entries = rows.group_by { |item| item.values_at(:resource_id, :date) }.values.map { |group| entry(group) }
    entries.sort_by { |item| [item[:date], item[:name].to_s, item[:resource_id].to_i] }
  end

  # The nearest free time after an empty range: the first specialist-days. A patient who asked for the afternoon is shown the
  # afternoon starts when there are any.
  def next_available(slots, requested_from: nil, days: NEXT_AVAILABLE_DAYS)
    candidates = slots
    if requested_from.present? && requested_from.hour >= 12
      minimum = (requested_from.hour * 60) + requested_from.min
      afternoon = slots.select { |slot| minute_of_day(local_time(slot)) >= minimum }
      candidates = afternoon if afternoon.present?
    end
    day_entries(candidates).first(days).map { |day| day.except(:duration_min) }
  end

  # Up to `count` of the sorted minutes, spread over the span: the first and the last, then each time the one farthest from those
  # already taken (the earlier on a tie), so the picks are not neighbours and the end of the day is in them.
  def spread(minutes, count = TIMES_PER_DAY)
    return minutes if minutes.size <= count

    chosen = [minutes.first, minutes.last]
    while chosen.size < count
      pick = (minutes - chosen).max_by { |minute| [chosen.map { |taken| (minute - taken).abs }.min, -minute] }
      chosen << pick
    end
    chosen.sort
  end

  def days_count(limit)
    limit.to_i.positive? ? [limit.to_i, MAX_DAYS].min : DEFAULT_DAYS
  end
  private_class_method :days_count

  def row(slot)
    local = local_time(slot)
    { resource_id: slot[:resource_id], name: slot[:resource_name], date: local.strftime('%Y-%m-%d'), minute: minute_of_day(local),
      duration_min: slot[:duration_min] }
  end
  private_class_method :row

  def entry(group)
    minutes = group.pluck(:minute).uniq.sort
    picked = spread(minutes)
    first = group.first
    { resource_id: first[:resource_id], name: first[:name], date: first[:date], times: picked.map { |minute| clock(minute) },
      more: minutes.size - picked.size, duration_min: first[:duration_min] }.compact
  end
  private_class_method :entry

  # The one visit length of the answer, to be said once at the top; nil when the slots differ in length (each entry then keeps its own).
  def shared_duration(slots, payload)
    durations = slots.filter_map { |slot| slot[:duration_min] }.uniq
    return payload[:duration_min] if durations.empty?

    durations.first if durations.one?
  end
  private_class_method :shared_duration

  def degraded(payload)
    return {} unless payload.dig(:availability, :status) == 'degraded'

    { availability: 'degraded', availability_note: DEGRADED_NOTE }
  end
  private_class_method :degraded

  # The start as the clock of the specialist: the slot carries its timezone next to the ISO time.
  def local_time(slot)
    time = Time.iso8601(slot[:starts_at].to_s)
    zone = ActiveSupport::TimeZone[slot[:timezone].to_s]
    zone ? time.in_time_zone(zone) : time
  end
  private_class_method :local_time

  def minute_of_day(time)
    (time.hour * 60) + time.min
  end
  private_class_method :minute_of_day

  def clock(minute)
    format('%<hour>02d:%<minute>02d', hour: minute / 60, minute: minute % 60)
  end
  private_class_method :clock
end
