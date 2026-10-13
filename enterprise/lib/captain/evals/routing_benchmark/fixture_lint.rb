# frozen_string_literal: true

# A calendar lint for a fixture, found without a model call and without a database (a port of the free-time check used to write the
# v2 fixtures). It mirrors Scheduling::AvailabilityService for the synthetic workspace: the interval [start, start + duration) of
# an expected booking must lie inside one work window (WorkRule) of the doctor for that weekday, and must not overlap a seeded
# appointment of the doctor or an appointment that an earlier turn of the dialogue books. Holidays, breaks and time off do not
# exist in the fixtures.
#
#   - An operation that pins `resource` is checked for that doctor, one that does not for every doctor: it passes when at least one
#     doctor is free (the v2 fixtures leave the doctor to the agent, "any resource that fits passes"). The duration is that of the
#     pinned `service`, else the shortest service of the workspace. A booking that only one doctor can take occupies that doctor for
#     the rest of the dialogue; when several can, the later turns are checked as if none was taken.
#   - A move (kind update) does not collide with the seeded appointments of the dialogue's contact: the old slot of the appointment
#     being moved never blocks the move (`previous_starts_at` narrows this to the one appointment). A cancellation is not checked.
#   - A business turn (`must_not_succeed`) names a taken or closed slot in the words of the customer. When the turn names a day and a
#     time and a doctor works then, one of the doctors who work then must have that slot taken, or the refusal could never happen.
#     The date and the time are read from the customer's words conservatively; a turn whose slot cannot be read is not checked.
# `problems` lists [{ dialogue:, turn:, message: }] and is empty for a sound fixture.
class Captain::Evals::RoutingBenchmark::FixtureLint
  WEEKDAY_STEMS = { 'воскресень' => 0, 'понедельник' => 1, 'вторник' => 2, 'сред' => 3, 'четверг' => 4, 'пятниц' => 5, 'суббот' => 6 }.freeze
  CLOCK = /(?<!\d)([01]?\d|2[0-3])[:.]([0-5]\d)(?!\d)/
  HOUR = /(?:^|\s)(?:в|на|к|около)\s+(\d{1,2})(?!\d|[:.]\d)/
  DAY_OF_MONTH = /(?<!\d)(\d{1,2})\s*-?\s*(?:го|е|ого|ое|ым)(?!\p{L})/
  DEFAULT_MINUTES = 30

  def initialize(fixture)
    @workspace = fixture.workspace
    @fixture = fixture
  end

  def problems
    # A workspace without work rules says nothing about the calendar (the availability search would find no slot at all).
    return [] if @workspace.fetch('slots', []).empty?

    @fixture.dialogues.flat_map { |dialogue| dialogue_problems(dialogue) }
  end

  private

  def dialogue_problems(dialogue)
    contact = dialogue['contact']
    booked = []
    dialogue.fetch('turns').each_with_index.flat_map do |turn, index|
      found = Array(turn.dig('expect', 'operations')).filter_map do |operation|
        check_operation(operation, contact, booked)
      end
      found.concat(business_problems(turn))
      found.map { |message| { dialogue: dialogue['id'], turn: index + 1, message: message } }
    end
  end

  def check_operation(operation, contact, booked)
    return unless operation['model'] == 'appointment'
    return if operation.key?('count') && operation['count'].to_i.zero?
    return if Captain::Evals::RoutingBenchmark::OperationCheck.kind_of(operation) == 'cancel'

    start = Captain::Evals::RoutingBenchmark::OperationCheck.expected_start(operation)
    return unless start

    from = Time.iso8601(start)
    minutes = operation['service'] ? duration(operation['service']) : shortest_duration
    ignore = ignored_seeds(operation, contact)
    candidates = operation['resource'] ? [operation['resource']] : resources.keys
    verdicts = candidates.index_with { |key| verdict(key, from, minutes, booked, ignore) }
    free = verdicts.select { |_key, result| result == :free }.keys
    booked << [free.first, from, minutes] if free.size == 1
    failure_message(start, minutes, verdicts) if free.empty?
  end

  def failure_message(start, minutes, verdicts)
    if verdicts.size == 1
      key, reason = verdicts.first
      return "#{start} (#{minutes} min) is not possible for #{key}: #{reason}"
    end

    outside = verdicts.count { |_key, why| why.to_s.start_with?('outside') }
    taken = verdicts.size - outside
    "#{start} (#{minutes} min) is free for no doctor: outside the work window of #{outside}, taken for #{taken} (#{taken_details(verdicts)})"
  end

  def taken_details(verdicts)
    verdicts.filter_map { |key, why| "#{key}: #{why}" if why.to_s.start_with?('taken') }.join('; ')
  end

  # :free, or "outside ..." / "taken by ..." for one doctor.
  def verdict(key, from, minutes, booked, ignore)
    local = from.in_time_zone(zone(key))
    return 'outside the work window: the interval crosses midnight' unless (local + minutes.minutes).to_date == local.to_date

    windows = windows_for(key, local.wday)
    start_minute = (local.hour * 60) + local.min
    unless windows.any? { |first, last| first <= start_minute && start_minute + minutes <= last }
      return "outside the work window (#{windows.map { |first, last| format('%02d:%02d-%02d:%02d', first / 60, first % 60, last / 60, last % 60) }.join(', ').presence || 'none that weekday'})"
    end

    busy = busy_with(key, from, from + minutes.minutes, booked, ignore)
    busy ? "taken by #{busy}" : :free
  end

  def busy_with(key, from, till, booked, ignore)
    seeded = seeds.find do |seed|
      seed[:resource] == key && !ignore.include?(seed) && from < seed[:ends_at] && seed[:starts_at] < till
    end
    return "seeded appointment of #{seeded[:contact]} at #{seeded[:starts_at].in_time_zone(zone(key)).strftime('%d.%m %H:%M')}" if seeded

    earlier = booked.find { |resource, start, minutes| resource == key && from < start + minutes.minutes && start < till }
    earlier ? 'an earlier booking of the dialogue' : nil
  end

  def ignored_seeds(operation, contact)
    return [] unless Captain::Evals::RoutingBenchmark::OperationCheck.kind_of(operation) == 'update'

    own = seeds.select { |seed| seed[:contact] == contact }
    previous = operation['previous_starts_at']
    previous ? own.select { |seed| seed[:starts_at] == Time.iso8601(previous) } : own
  end

  # A business turn: the slot the customer asks for must be taken for a doctor who works then, or no doctor works then.
  def business_problems(turn)
    return [] if Array(turn.dig('expect', 'must_not_succeed')).empty?

    from = requested_start(turn)
    return [] unless from

    minutes = shortest_duration
    verdicts = resources.keys.index_with { |key| verdict(key, from, minutes, [], []) }
    working = verdicts.reject { |_key, result| result.to_s.start_with?('outside') }
    return [] if working.empty? || working.values.any? { |result| result != :free }

    ["the customer asks for #{from.iso8601}, which is free for every doctor who works then: the business refusal could never happen"]
  end

  # The day and the time the customer names in this message (the day of the month or the weekday, and a clock time), or nil.
  def requested_start(turn)
    return unless turn['at']

    text = turn['customer'].to_s.downcase
    now = Time.iso8601(turn['at'])
    date = day_named(text, now)
    clock = clock_named(text)
    return unless date && clock

    Time.new(date.year, date.month, date.day, clock[0], clock[1], 0, now.utc_offset)
  end

  def day_named(text, now)
    day = text[DAY_OF_MONTH, 1]&.to_i
    return Date.new(now.year, now.month, day) if day && Date.valid_date?(now.year, now.month, day)

    wday = WEEKDAY_STEMS.find { |stem, _| text.include?(stem) }&.last
    return unless wday

    ((now.to_date + 1)..(now.to_date + 7)).find { |date| date.wday == wday }
  end

  def clock_named(text)
    if (match = text.match(CLOCK))
      [match[1].to_i, match[2].to_i]
    elsif (match = text.match(HOUR))
      hour = match[1].to_i
      [hour < 7 ? hour + 12 : hour, 0]
    end
  end

  # ---- the workspace -----------------------------------------------------------------------------------------------------

  def resources
    @resources ||= @workspace.fetch('resources', []).to_h { |row| [row['key'], row.fetch('timezone', 'Asia/Almaty')] }
  end

  def zone(key) = resources.fetch(key, 'Asia/Almaty')

  def duration(service_key)
    @workspace.fetch('services', []).find { |row| row['key'] == service_key }&.fetch('duration_min', DEFAULT_MINUTES) || DEFAULT_MINUTES
  end

  def shortest_duration
    @shortest_duration ||= @workspace.fetch('services', []).map { |row| row.fetch('duration_min', DEFAULT_MINUTES).to_i }.min || DEFAULT_MINUTES
  end

  def windows_for(key, wday)
    @workspace.fetch('slots', []).select { |row| row['resource'] == key && row['weekday'] == wday }.map { |row| [row['start_minute'], row['end_minute']] }
  end

  def seeds
    @seeds ||= @workspace.fetch('appointments', []).map do |row|
      starts = Time.iso8601(row['starts_at'])
      { resource: row['resource'], contact: row['contact'], starts_at: starts, ends_at: starts + duration(row['service']).minutes }
    end
  end
end
