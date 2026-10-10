class Crm::Appointments::SourceCreationTime
  def self.for(appointment)
    attributes = appointment.custom_attributes.to_h
    value = attributes['medelement_source_created_at'].to_s.strip
    zone_name = attributes['medelement_source_timezone'].presence || appointment.resource&.timezone || Scheduling::Constants::DEFAULT_TIMEZONE
    zone = ActiveSupport::TimeZone[zone_name]
    return unless zone

    case value
    when /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\z/
      zone.iso8601(value)
    when /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/
      zone.strptime(value, '%Y-%m-%d %H:%M:%S')
    when /\A\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}:\d{2}\z/
      zone.strptime(value, '%d.%m.%Y %H:%M:%S')
    end
  rescue ArgumentError
    nil
  end
end
