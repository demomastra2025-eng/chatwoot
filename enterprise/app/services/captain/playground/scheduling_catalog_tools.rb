module Captain::Playground::SchedulingCatalogTools
  private

  def resource!(id)
    record = record!('resources', id)
    raise ArgumentError, 'Specialist is unavailable' unless record['active']

    record
  end

  def service!(id, resource: nil)
    record = record!('services', id)
    raise ArgumentError, 'Service is unavailable' unless record['active']
    raise ArgumentError, 'Service is not available for this specialist' if resource && !resource['service_ids'].include?(record['id'])

    record
  end

  def scheduling_resources
    records = @data['resources'].select { |record| record['active'] }
    query = @args['query'].presence || @args['name'].presence || @args['specialty'].presence
    records = records.select { |record| [record['name'], record['specialty']].join(' ').downcase.include?(query.downcase) } if query
    records = records.select { |record| record['service_ids'].include?(@args['service_id'].to_i) } if @args['service_id']
    { resources: records.deep_dup, total_count: records.size, simulated: true }
  end

  def scheduling_services
    records = @data['services'].select { |record| record['active'] }
    queries = service_queries
    records = records.select { |record| queries.any? { |query| record['name'].downcase.include?(query) } } if queries.any?
    if @args['resource_id']
      resource = resource!(@args['resource_id'])
      records = records.select { |record| resource['service_ids'].include?(record['id']) }
    end
    { services: records.deep_dup, total_count: records.size, simulated: true }
  end

  # The service search takes a list of mentions (queries); the older single query or name still works in a simulated run.
  def service_queries
    Array(@args['queries'].presence || @args['query'].presence || @args['name'].presence).map { |query| query.to_s.downcase }
  end
end
