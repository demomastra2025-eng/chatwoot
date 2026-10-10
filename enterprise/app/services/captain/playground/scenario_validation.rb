module Captain::Playground::ScenarioValidation
  private

  def validate!
    %w[contacts resources services pipelines stages deals appointments tasks notes messages confirmations grants].each do |key|
      records = data[key]
      unless records.is_a?(Array) && records.size <= Captain::Playground::Scenario::MAX_RECORDS && records.all?(Hash)
        raise ArgumentError, "Invalid scenario #{key}"
      end
    end
    data['resources'].each { |record| validate_resource!(record) }
    raise ArgumentError, 'Invalid field catalogue' unless data['custom_fields'].is_a?(Array) && data['custom_fields'].size <= 200
    data['contacts'].each { |record| validate_contact!(record) }
    data['deals'].each { |record| validate_deal!(record) }
    data['appointments'].each { |record| validate_appointment!(record) }
    Captain::Playground::Scenario::FIXTURE_COLLECTIONS.each do |key|
      records = data[key]
      raise ArgumentError, "Invalid scenario #{key}" unless records.is_a?(Array) && records.size <= Captain::Playground::Scenario::MAX_RECORDS && records.all?(Hash)
    end
    data.values.select { |value| value.is_a?(Array) }.each do |records|
      ids = records.filter_map { |record| record['id'] if record.is_a?(Hash) }
      raise ArgumentError, 'Synthetic IDs must be unique positive session-local integers' unless ids.uniq == ids && ids.all? { |id| id.is_a?(Integer) && id.positive? && id < Captain::Playground::SyntheticNamespace::STRIDE }
    end
  end

  def validate_resource!(record)
    raise ArgumentError, 'Unknown resource timezone' unless ActiveSupport::TimeZone[record['timezone']]

    %w[work_rules break_rules].each do |key|
      rules = record[key]
      raise ArgumentError, 'Invalid resource calendar' unless rules.is_a?(Array) && rules.size <= 100

      rules.each do |rule|
        valid = rule.is_a?(Hash) && rule['weekday'].is_a?(Integer) && rule['weekday'].between?(0, 6) &&
                rule['start_minute'].is_a?(Integer) && rule['end_minute'].is_a?(Integer) &&
                rule['start_minute'].between?(0, 1439) && rule['end_minute'].between?(1, 1440) && rule['end_minute'] > rule['start_minute']
        raise ArgumentError, 'Invalid resource calendar interval' unless valid
      end
    end
  end

  def validate_contact!(record)
    raise ArgumentError, 'Contact name is required' if record['name'].blank? || record['name'].to_s.length > 255

    phone = record['phone_number']
    raise ArgumentError, 'Contact phone must use E.164 format' if phone.present? && !phone.to_s.match?(/\A\+[1-9]\d{7,14}\z/)
    raise ArgumentError, 'Contact custom attributes must be an object' unless record['custom_attributes'].is_a?(Hash)
  end

  def validate_deal!(record)
    amount = BigDecimal(record['amount'].to_s)
    return if amount.finite? && amount >= 0 && amount.frac.zero?

    raise ArgumentError, 'Deal amount must be a nonnegative whole number'
  end

  def validate_appointment!(record)
    raise ArgumentError, 'Appointment end must be after its start' unless Time.iso8601(record['ends_at']) > Time.iso8601(record['starts_at'])

    resource = data['resources'].find { |item| item['id'] == record['resource_id'] }
    raise ArgumentError, 'Unknown appointment resource' unless resource
    patient_id = record['patient_contact_id'] || record['contact_id']
    raise ArgumentError, 'Unknown synthetic patient' unless data['contacts'].any? { |item| item['id'] == patient_id }
    return if record['service_id'].blank?

    service = data['services'].find { |item| item['id'] == record['service_id'] }
    raise ArgumentError, 'Unknown appointment service' unless service
    raise ArgumentError, 'Service is not available for this specialist' unless resource['service_ids'].include?(record['service_id'])
  end
end
