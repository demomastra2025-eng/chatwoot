module Scheduling::ResourceScheduleInput
  private

  def raw_schedule_rule_sets
    @raw_schedule_rule_sets ||= begin
      # JSON params have already been deep-munged: [null] becomes []. Read the
      # original body so a malformed set cannot become a destructive clear.
      raw = request.media_type == 'application/json' ? JSON.parse(request.raw_post) : params.to_unsafe_h
      raise ArgumentError, 'schedule payload must be an object' unless raw.is_a?(Hash)

      raw.slice('work_rules', 'break_rules').symbolize_keys
    end
  rescue JSON::ParserError
    raise ArgumentError, 'schedule payload must be valid JSON'
  end
end
