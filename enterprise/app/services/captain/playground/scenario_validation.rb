module Captain::Playground::ScenarioValidation
  private

  def validate!
    %w[contacts resources services pipelines stages deals appointments tasks notes messages confirmations grants].each do |key|
      records = data[key]
      unless records.is_a?(Array) && records.size <= Captain::Playground::Scenario::MAX_RECORDS && records.all?(Hash)
        raise ArgumentError, "Invalid scenario #{key}"
      end
    end
    data['contacts'].each { |record| validate_contact!(record) }
    data['deals'].each { |record| validate_deal!(record) }
    data['appointments'].each { |record| validate_appointment!(record) }
  end

  def validate_contact!(record)
    raise ArgumentError, 'Contact name is required' if record['name'].blank? || record['name'].to_s.length > 255

    phone = record['phone_number']
    raise ArgumentError, 'Contact phone must use E.164 format' if phone.present? && !phone.to_s.match?(/\A\+[1-9]\d{7,14}\z/)
    raise ArgumentError, 'Contact custom attributes must be an object' unless record['custom_attributes'].is_a?(Hash)
  end

  def validate_deal!(record)
    amount = BigDecimal(record['amount'].to_s)
    unless amount.finite? && amount >= 0 && amount.frac.zero?
      raise ArgumentError, 'Deal amount must be a nonnegative whole number'
    end
  end

  def validate_appointment!(record)
    unless Time.iso8601(record['ends_at']) > Time.iso8601(record['starts_at'])
      raise ArgumentError, 'Appointment end must be after its start'
    end
    resource = data['resources'].find { |item| item['id'] == record['resource_id'] }
    raise ArgumentError, 'Unknown appointment resource' unless resource
    return if record['service_id'].blank?

    service = data['services'].find { |item| item['id'] == record['service_id'] }
    raise ArgumentError, 'Unknown appointment service' unless service
    raise ArgumentError, 'Service is not available for this specialist' unless resource['service_ids'].include?(record['service_id'])
  end
end
