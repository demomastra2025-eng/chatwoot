class Integrations::Medelement::ProviderCommands::Preflight
  Result = Data.define(:remote_reception, :reception_codes)
  StateChanged = Class.new(StandardError)
  SlotConflict = Class.new(StandardError)
  SlotUnavailable = Class.new(StandardError)

  def initialize(command:, client:, configuration:)
    @command = command
    @client = client
    @configuration = configuration
  end

  def perform
    remote_reception = verify_remote_reception! unless command.create_reception?
    verify_timetable! if command.create_reception? || command.move_reception?
    receptions = destination_receptions
    raise SlotConflict, 'Medelement destination slot is occupied' if overlap?(receptions)

    Result.new(remote_reception: remote_reception, reception_codes: reception_codes(receptions))
  end

  private

  attr_reader :command, :client, :configuration

  def verify_remote_reception!
    return if command.create_patient? || command.update_patient?

    remote = client.get_reception(reception_code: provider_reception_code)
    verify_remote_patient!(remote)
    verify_remote_specialist!(remote)
    verify_remote_state!(remote)

    remote
  end

  def verify_remote_patient!(remote)
    return if provider_patient_code.blank?
    return if remote_patient_code(remote) == provider_patient_code.to_s

    raise StateChanged, 'Medelement reception patient changed'
  end

  def verify_remote_specialist!(remote)
    return if local_specialist_code.blank? || remote['SPECIALIST_CODE'].to_s == local_specialist_code

    raise StateChanged, 'Medelement reception specialist changed'
  end

  def verify_remote_state!(remote)
    return verify_remove_state!(remote) if command.remove_reception?
    return unless command.move_reception?

    raise StateChanged, 'Medelement reception has been removed' if remote['REMOVED'].to_i == 1
    raise StateChanged, 'Medelement reception time changed' unless remote_time_matches_local?(remote)
  end

  def destination_receptions
    return [] unless command.create_reception? || command.move_reception?

    range = destination_calendar_range
    client.get_receptions(
      company_cabinet_code: command.request_snapshot.fetch('company_cabinet_code'),
      specialist_code: specialist_code,
      begin_datetime: provider_datetime(range.begin),
      end_datetime: provider_datetime(range.end)
    )
  end

  def verify_remove_state!(remote)
    return if remote['REMOVED'].to_i == 1

    raise StateChanged, 'Medelement reception is not active' unless remote['ACTIVE'].to_i == 1

    calendar_reception = source_receptions.find do |reception|
      reception['RECEPTION_CODE'].to_s == provider_reception_code
    end
    raise StateChanged, 'Medelement reception payment state is unavailable' if calendar_reception.blank?

    paid = calendar_reception['PAID'].to_s
    return if paid.blank? || paid == 'not'

    raise StateChanged, 'Paid Medelement reception cannot be removed'
  end

  def source_receptions
    range = source_calendar_range
    client.get_receptions(
      company_cabinet_code: command.request_snapshot.fetch('company_cabinet_code'),
      specialist_code: specialist_code,
      begin_datetime: provider_datetime(range.begin),
      end_datetime: provider_datetime(range.end)
    )
  end

  def verify_timetable!
    timetable = client.timetable(
      specialist_code: specialist_code,
      starts_on: destination_start.in_time_zone(reception_snapshot.fetch('time_zone')).to_date,
      ends_on: destination_end.in_time_zone(reception_snapshot.fetch('time_zone')).to_date
    )
    intervals = working_intervals(timetable)
    return if destination_covered?(intervals)

    raise SlotUnavailable, 'Medelement timetable does not cover the destination slot'
  end

  def working_intervals(timetable)
    timetable.to_h.values.flat_map { |day| Array(day['timetable']) }
             .select { |slot| slot['working'] == true }
             .filter_map { |slot| parsed_interval(slot) }
             .sort_by(&:first)
  end

  def destination_covered?(intervals)
    cursor = destination_start
    intervals.each do |starts_at, ends_at|
      next if ends_at <= cursor
      break if starts_at > cursor

      cursor = [cursor, ends_at].max
      break if cursor >= destination_end
    end
    cursor >= destination_end
  end

  def parsed_interval(slot)
    starts_at = parse_provider_time(slot['start'])
    ends_at = parse_provider_time(slot['end'])
    [starts_at, ends_at] if starts_at.present? && ends_at.present? && ends_at > starts_at
  end

  def overlap?(receptions)
    receptions.any? do |reception|
      next false if reception['REMOVED'].to_i == 1
      next false if reception['RECEPTION_CODE'].to_s == provider_reception_code.to_s

      starts_at = parse_provider_time(reception['STARTTIME'])
      ends_at = parse_provider_time(reception['ENDTIME'])
      starts_at.present? && ends_at.present? && starts_at < destination_end && ends_at > destination_start
    end
  end

  def reception_codes(receptions)
    receptions.filter_map do |reception|
      reception['RECEPTION_CODE'].to_s.presence unless reception['REMOVED'].to_i == 1
    end.uniq
  end

  def remote_patient_code(remote)
    remote['PROFILE_CODE'].presence || remote['PATIENT_CODE'].presence
  end

  def remote_time_matches_local?(remote)
    parse_provider_time(remote['STARTTIME'])&.to_i == snapshot_time('source_starts_at').to_i &&
      parse_provider_time(remote['ENDTIME'])&.to_i == snapshot_time('source_ends_at').to_i
  end

  def specialist_code
    local_specialist_code.presence || raise(KeyError, 'appointment has no Medelement specialist reference')
  end

  def local_specialist_code
    reception_snapshot.fetch('specialist_code').to_s
  end

  def provider_patient_code
    command.request_snapshot['provider_patient_code'].presence || command.provider_patient_code
  end

  def provider_reception_code
    command.request_snapshot['provider_reception_code'].to_s
  end

  def destination_start
    snapshot_time('destination_starts_at')
  end

  def destination_end
    snapshot_time('destination_ends_at')
  end

  def destination_calendar_range
    calendar_range(destination_start, destination_end)
  end

  def source_calendar_range
    calendar_range(snapshot_time('source_starts_at'), snapshot_time('source_ends_at'))
  end

  def calendar_range(starts_at, ends_at)
    zone = ActiveSupport::TimeZone[reception_snapshot.fetch('time_zone')]
    starts_on = starts_at.in_time_zone(zone).to_date
    ends_on = ends_at.in_time_zone(zone).to_date
    exclusive_end = ends_on + 1.day

    Range.new(
      zone.local(starts_on.year, starts_on.month, starts_on.day),
      zone.local(exclusive_end.year, exclusive_end.month, exclusive_end.day),
      true
    )
  end

  def reception_snapshot
    @reception_snapshot ||= command.request_snapshot.fetch('reception')
  end

  def snapshot_time(key)
    Time.iso8601(reception_snapshot.fetch(key))
  end

  def provider_datetime(value)
    value.in_time_zone(reception_snapshot.fetch('time_zone')).strftime('%d.%m.%Y %H:%M:%S')
  end

  def parse_provider_time(value)
    ActiveSupport::TimeZone[reception_snapshot.fetch('time_zone')].parse(value.to_s)
  end
end
