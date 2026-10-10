class Scheduling::Appointments::PlaygroundRunStamp
  KEY = 'captain_playground'.freeze

  def self.apply(attributes)
    result = attributes.to_h.except(KEY)
    policy = Current.playground_run_policy if Current.respond_to?(:playground_run_policy)
    result[KEY] = policy.deep_dup unless policy.nil?
    result
  end
end
