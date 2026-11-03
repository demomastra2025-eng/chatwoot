require 'digest'

# Identity of the catalogue that a real read is allowed to consult, captured
# before provider I/O. Broad searches are bounded and loaded in batches.
class Captain::Playground::SchedulingReadSnapshot
  MAX_RESOURCES = 2_000
  MAX_SERVICES = 10_000
  RESOURCE_FIELDS = %w[id created_at timezone slot_duration_min custom_attributes].freeze
  SERVICE_FIELDS = %w[id created_at duration_min custom_attributes].freeze

  attr_reader :generation

  def self.for_arguments(session, arguments)
    arguments = arguments.to_h.with_indifferent_access
    requested = arguments[:resource_ids].presence || Array(arguments[:resource_id].presence)
    resources = Scheduling::AvailableSlotSearchService.normalize_resource_ids(requested).presence
    services = Array(Scheduling::IntegerNumericNormalizer.optional_positive_id(arguments[:service_id])).presence
    new(session, resource_ids: resources, service_ids: services)
  end

  def self.for_slots(session, slots)
    new(session, resource_ids: slots.pluck('resource_id').compact.uniq, service_ids: slots.pluck('service_id').compact.uniq)
  end

  def initialize(session, resource_ids:, service_ids:)
    @account = session.account
    permissions = session.permissions
    @generation = permissions['generation']
    @read_enabled = permissions['read'] == true
    return unless @read_enabled

    @resources = catalogue(@account.scheduling_resources.available_for_scheduling, resource_ids, RESOURCE_FIELDS, MAX_RESOURCES)
    @services = catalogue(@account.scheduling_services.active, service_ids, SERVICE_FIELDS, MAX_SERVICES)
    @hook = hook_identity
  end

  def valid? = @read_enabled && !@resources.nil? && !@services.nil?

  def timezone(resource_id)
    @resources&.dig(resource_id.to_i, :timezone)
  end

  def binding_for(resource_id, service_id)
    return unless valid?

    resource = @resources[resource_id.to_i]
    service = @services[service_id.to_i] if service_id.present?
    return unless resource
    return if service_id.present? && !service

    digest([@account.id, resource[:digest], service&.fetch(:digest), @hook])
  end

  private

  def catalogue(scope, ids, fields, limit)
    rows = bounded_rows(scope, ids, fields, limit)
    return unless rows

    rows.to_h { |values| projected_record(fields, values) }.freeze
  end

  def bounded_rows(scope, ids, fields, limit)
    ids = Array(ids).map(&:to_i).uniq if ids
    return if ids && ids.size > limit

    scope = scope.where(id: ids) if ids
    rows = scope.limit(limit + 1).pluck(*fields)
    rows if rows.size <= limit
  end

  def projected_record(fields, values)
    attributes = fields.zip(values).to_h
    identity = fields == RESOURCE_FIELDS ? resource_identity(attributes) : service_identity(attributes)
    [attributes.fetch('id'), { digest: digest(identity), timezone: attributes['timezone']&.freeze }.freeze]
  end

  def hook_identity
    hook = @account.hooks.enabled.find_by(app_id: 'medelement')
    return unless hook

    configuration = Integrations::Medelement::Configuration.new(hook: hook)
    digest([hook.id, hook.status, hook.created_at,
            configuration.organization_id, configuration.company_login, configuration.time_zone])
  end

  def resource_identity(attributes)
    attrs = attributes.fetch('custom_attributes').to_h
    cabinets = Array(attrs['medelement_cabinets']).filter_map do |payload|
      Integrations::Medelement::CabinetAttributes.code(payload).to_s.presence
    end.uniq.sort
    [attributes.values_at('id', 'created_at', 'timezone', 'slot_duration_min'), attrs['medelement_specialist_code'], cabinets,
     attrs['slot_grid_min'], attrs['medelement_reception_time'], attrs['slot_grid_checked_at'].present?]
  end

  def service_identity(attributes)
    [attributes.values_at('id', 'created_at', 'duration_min'), attributes.fetch('custom_attributes').to_h['medelement_nomenclature_code'].to_s.strip]
  end

  def digest(value)
    Digest::SHA256.hexdigest(JSON.generate(value.as_json)).freeze
  end
end
