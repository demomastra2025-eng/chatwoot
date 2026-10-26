# frozen_string_literal: true

# In a patient conversation (the agent scope) the scheduling tools read only from now on, in the clinic's clock: a free time or
# working hours before now are never returned. A range that began earlier starts now; a range that ended before now is not read
# at all and is answered as passed, with the clinic's current time, so the agent says so and offers the nearest free times. Staff
# and Copilot keep the range they asked for.
module Captain::Tools::Account::AgentTimeRange
  RANGE_PASSED_STATUS = 'range_passed'
  RANGE_PASSED_NOTE = 'The requested range ended before now (%<now>s), so nothing in it can be offered or booked. If the patient ' \
                      'named a day or a time that has passed, say so with its date and offer the nearest free times'

  private

  # [from, to] of the range the tool reads: from is never before now in the agent scope. nil when the whole range is before now.
  def present_range(range_from, range_to)
    return [range_from, range_to] unless agent_scope?

    now = Time.current.in_time_zone(range_from.time_zone)
    return if range_to <= now

    [[range_from, now].max, range_to]
  end

  # The note of a passed range; ending: how the tool gives the nearest free times.
  def range_passed_note(ending)
    "#{format(RANGE_PASSED_NOTE, now: clinic_now_label)} #{ending}"
  end

  # "Monday, 26 October 2026 (2026-10-26), 14:05": now in the clinic's clock (the zone of the Now block of the prompt).
  def clinic_now_label
    Time.current.in_time_zone(scheduling_time_zone).strftime("#{Captain::PromptClock::LONG_DATE_FORMAT}, %H:%M")
  end
end
