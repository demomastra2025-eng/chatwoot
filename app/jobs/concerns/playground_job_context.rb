module PlaygroundJobContext
  extend ActiveSupport::Concern

  included do
    before_enqueue :capture_playground_run_policy
    around_perform :restore_playground_run_policy
  end

  def serialize
    payload = super
    payload['captain_playground'] = @playground_run_policy.deep_dup unless @playground_run_policy.nil?
    payload
  end

  def deserialize(payload)
    super
    @playground_run_policy = if payload.key?('captain_playground')
                               payload['captain_playground'].nil? ? {} : payload['captain_playground'].deep_dup
                             end
  end

  private

  def capture_playground_run_policy
    @playground_run_policy = Current.playground_run_policy&.deep_dup if @playground_run_policy.nil?
  end

  def restore_playground_run_policy(&)
    policy = Outbound::PlaygroundDeliveryPolicy.for_run(@playground_run_policy)
    Outbound::PlaygroundDeliveryPolicy.with(policy, &)
  end
end
