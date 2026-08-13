class Integrations::Medelement::ConflictEntityPreloader
  SPECIALIST_CODE_KEY = 'medelement_specialist_code'.freeze
  SERVICE_CODE_KEY = 'medelement_nomenclature_code'.freeze

  def initialize(account:, conflicts:)
    @account = account
    @details = conflicts.map(&:details)
    @resources = load_resources
    @services = load_services
    @appointments = load_appointments
  end

  def resource_for(details)
    resources[:id][details['resource_id'].to_i] || lookup(resources[:code], details['specialist_code'])
  end

  def service_for(details)
    services[:id][details['service_id'].to_i] || lookup(services[:code], details['service_code'])
  end

  def appointment_for(details)
    appointments[:id][details['appointment_id'].to_i] || lookup(appointments[:reception], details['reception_code'])
  end

  private

  attr_reader :account, :appointments, :details, :resources, :services

  def lookup(records, key)
    records[key.to_s] if key.present?
  end

  def load_resources
    records = scoped_records(
      account.scheduling_resources,
      ids_for('resource_id'),
      SPECIALIST_CODE_KEY,
      values_for('specialist_code')
    )
    {
      id: records.index_by(&:id),
      code: records.index_by { |record| record.custom_attributes[SPECIALIST_CODE_KEY].to_s }
    }
  end

  def load_services
    records = scoped_records(
      account.scheduling_services,
      ids_for('service_id'),
      SERVICE_CODE_KEY,
      values_for('service_code')
    )
    {
      id: records.index_by(&:id),
      code: records.index_by { |record| record.custom_attributes[SERVICE_CODE_KEY].to_s }
    }
  end

  def load_appointments
    ids = ids_for('appointment_id')
    external_refs = values_for('reception_code').map { |code| "medelement:reception:#{code}" }
    scope = account.scheduling_appointments.includes(:resource, :service)
    records = combined_scope(scope, ids, :external_ref, external_refs).to_a
    {
      id: records.index_by(&:id),
      reception: records.each_with_object({}) do |record, index|
        reception_code = record.custom_attributes['medelement_reception_code'].presence ||
                         record.external_ref.to_s.delete_prefix('medelement:reception:').presence
        index[reception_code.to_s] = record if reception_code.present?
      end
    }
  end

  def scoped_records(scope, ids, json_key, values)
    combined_scope(scope, ids, "custom_attributes ->> '#{json_key}'", values).to_a
  end

  def combined_scope(scope, ids, field, values)
    return scope.none if ids.empty? && values.empty?

    id_scope = scope.where(id: ids)
    value_scope = records_by(scope, field, values)
    return id_scope if values.empty?
    return value_scope if ids.empty?

    id_scope.or(value_scope)
  end

  def records_by(scope, field, values)
    field.is_a?(Symbol) ? scope.where(field => values) : scope.where("#{field} IN (?)", values)
  end

  def ids_for(key)
    values_for(key).filter_map { |value| Integer(value, exception: false) }.select(&:positive?)
  end

  def values_for(key)
    details.filter_map { |item| item[key].presence }.uniq
  end
end
