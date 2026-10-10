module Captain::Playground::AppointmentQueryTools
  private

  def search_appointments
    require_caller_filter!
    family_lookup = @args['client_identifier'].present? || bounded_name_lookup?
    records = filter_search_appointments(scoped_search_appointments(family_lookup))
    limited = records.sort_by { |record| record['starts_at'] }.last(20).reverse
    { success: true, appointments: limited.map { |record| appointment_result(record, family_lookup: family_lookup).except(:success, :simulated) },
      has_more: records.size > 20, simulated: true }
  end

  def scoped_search_appointments(family_lookup)
    records = @data['appointments']
    if @args['client_identifier'].present?
      iin = normalized_iin(@args['client_identifier'])
      records = records.select { |record| record['client_identifier'] == iin }
    elsif family_lookup
      records = records.select { |record| record['client_name'].to_s.squish.casecmp?(@args['client_name'].to_s.squish) }
    else
      records = records.select { |record| record['patient_contact_id'] == caller['id'] }
      if @args['client_name'].present?
        records = records.select do |record|
          record['client_name'].to_s.downcase.include?(@args['client_name'].downcase)
        end
      end
    end
    records
  end

  def filter_search_appointments(records)
    %w[resource_id status].each do |key|
      records = records.select { |record| record[key].to_s == @args[key].to_s } if @args[key]
    end
    from = parse_time(@args['from']) if @args['from']
    to = parse_time(@args['to']) if @args['to']
    raise ArgumentError, 'Invalid appointment date range' if from && to && from >= to

    records.select { |record| within_appointment_range?(parse_time(record['starts_at']), from: from, to: to, exclusive_end: true) }
  end

  def within_appointment_range?(start, from:, to:, exclusive_end: false)
    ending_matches = to.nil? || (exclusive_end ? start < to : start <= to)
    (from.nil? || start >= from) && ending_matches
  end

  def bounded_name_lookup?
    return false if @args['client_name'].blank? || @args['resource_id'].blank? || @args['from'].blank? || @args['to'].blank?

    from = parse_time(@args['from'])
    to = parse_time(@args['to'])
    to > from && to - from <= 1.day
  end

  def list_my_appointments
    records = @data['appointments'].select { |record| record['patient_contact_id'] == caller['id'] }
    status = @args['status'].presence || 'any'
    raise ArgumentError, 'Invalid status' unless %w[scheduled completed cancelled no_show any].include?(status)

    records = records.select { |record| appointment_status_matches?(record, status) }
    records = filter_patient_appointment_dates(records)
    offset = Integer(@args['offset'] || 0)
    limit = Integer(@args['limit'] || 10).clamp(1, 20)
    raise ArgumentError, 'Invalid pagination' if offset.negative?

    page = records.sort_by { |record| record['starts_at'] }.reverse.drop(offset).first(limit)
    { success: true, total: records.size, has_more: records.size > offset + limit,
      appointments: page.map { |record| @scenario.appointment_card(record) }, simulated: true }
  end

  def appointment_status_matches?(record, status)
    status == 'any' || record['status'] == status || (status == 'scheduled' && record['status'] == 'confirmed')
  end

  def filter_patient_appointment_dates(records)
    from = Date.iso8601(@args['date_from']) if @args['date_from'].present?
    to = Date.iso8601(@args['date_to']) if @args['date_to'].present?
    records.select do |record|
      start = parse_time(record['starts_at']).in_time_zone(@data['timezone']).to_date
      within_appointment_range?(start, from: from, to: to)
    end
  end
end
