require 'digest'

class Scheduling::ResourceScheduleRevision
  class << self
    def generate(resource)
      Digest::SHA256.hexdigest(canonical_payload(resource).to_json)
    end

    private

    def canonical_payload(resource)
      {
        inherit_working_hours_from_account: resource.inherit_working_hours_from_account?,
        timezone: resource.timezone,
        work_rules: resource.work_rules.reorder(:weekday, :start_minute, :end_minute, :active).pluck(
          :weekday, :start_minute, :end_minute, :active
        ),
        break_rules: resource.break_rules.reorder(:weekday, :start_minute, :end_minute, :title, :active).pluck(
          :weekday, :start_minute, :end_minute, :title, :active
        )
      }
    end
  end
end
