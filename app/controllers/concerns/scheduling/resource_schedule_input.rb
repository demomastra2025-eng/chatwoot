module Scheduling::ResourceScheduleInput
  private

  def raw_schedule_rule_sets
    @raw_schedule_rule_sets ||= begin
      # Rails params have already been deep-munged: null list entries disappear.
      # Parse the original body so malformed lists cannot become valid updates.
      raw =
        case request.media_type
        when 'application/json' then JSON.parse(request.raw_post)
        when 'application/x-www-form-urlencoded' then Rack::Utils.parse_nested_query(request.raw_post)
        else params.to_unsafe_h
        end
      raise ArgumentError, 'schedule payload must be an object' unless raw.is_a?(Hash)

      raw.slice('work_rules', 'break_rules').symbolize_keys
    end
  rescue JSON::ParserError
    raise ArgumentError, 'schedule payload must be valid JSON'
  end
end
