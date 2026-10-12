require 'digest'

class Captain::Playground::ActionApproval
  MAX_PREVIEWS = 20
  # What the digest of a preview covers. An older preview has no actor_id: its digest was made without it, and slice leaves it out.
  FINGERPRINT_KEYS = %w[tool arguments target generation binding actor_id].freeze

  def initialize(session)
    @session = session
    @executor = Captain::Playground::RealToolExecutor.new(session)
  end

  def preview(tool_id, arguments)
    @session.validate_active_agent!
    raise ArgumentError, 'Changing real data is disabled' unless @session.write_enabled?

    prepared = @executor.prepare(tool_id, arguments)
    current = @session.permissions
    raise ArgumentError, 'Changing real data is disabled' unless current['read'] == true && current['write'] == true
    # actor_id: the agent whose profile the action belongs to. It is the owner of a council part, which is not always the session's
    # active agent, so the confirmation runs the action as that agent and not as the one that holds the conversation.
    action = {
      'tool' => tool_id.to_s, 'arguments' => prepared[:arguments].deep_stringify_keys,
      'target' => prepared[:target].deep_stringify_keys, 'generation' => current['generation'],
      'binding' => @session.context_reference.stringify_keys, 'actor_id' => @session.assistant.id
    }
    digest = fingerprint(action)
    previews = @session.data['action_previews'] ||= []
    existing = previews.find { |item| item['digest'] == digest && item['status'] == 'pending' && item['expires_at'] > Time.current.to_i }
    return existing if existing

    previews.each do |item|
      item['status'] = 'expired' if item['status'] == 'pending' && item['expires_at'].to_i <= Time.current.to_i
      item['status'] = 'revoked' if item['status'] == 'pending' && item['tool'] == tool_id.to_s && item['target'] == action['target']
    end

    raise ArgumentError, 'Too many pending real actions' if previews.count { |item| item['status'] == 'pending' } >= MAX_PREVIEWS

    action.merge!('id' => SecureRandom.uuid, 'digest' => digest, 'status' => 'pending', 'expires_at' => 20.minutes.from_now.to_i)
    previews << action
    action
  end

  def confirm(id:, digest:)
    current = @session.permissions
    action = Array(@session.data['action_previews']).find { |item| item['id'] == id }
    unless action && action['digest'] == digest && action['status'] == 'pending' && action['expires_at'] > Time.current.to_i &&
           @session.write_enabled? && action['generation'] == current['generation'] &&
           action['binding'] == @session.context_reference.stringify_keys
      raise ArgumentError, 'The real-action preview expired, changed, or was revoked'
    end
    @session.validate_active_agent!
    executor = executor_for(action['actor_id'])
    prepared = executor.prepare(action['tool'], action['arguments'])
    current = @session.permissions
    unless current['read'] == true && current['write'] == true && current['generation'] == action['generation'] &&
           action['binding'] == @session.context_reference.stringify_keys
      raise ArgumentError, 'The real-action confirmation was revoked'
    end
    unless prepared[:target].deep_stringify_keys == action['target'] && fingerprint(action.slice(*FINGERPRINT_KEYS)) == digest
      raise ArgumentError, 'The target or payload changed; review a new preview'
    end

    # A replay cannot repeat a partially completed domain or provider write.
    action['status'] = 'executing'
    action['confirmed_at'] = Time.current.iso8601
    @session.save!
    @session.validate_active_agent!
    unless action['binding'] == @session.context_reference.stringify_keys
      raise ArgumentError, 'The acting agent changed; review a new preview'
    end
    policy = Outbound::PlaygroundDeliveryPolicy.issue(
      @session.context_reference.merge(mode: 'workspace', run_id: SecureRandom.uuid, delivery_enabled: false,
                                       action_id: action['id'], action_digest: digest, generation: action['generation'],
                                       tool: action['tool'], arguments: action['arguments'], target: action['target'],
                                       actor_id: action['actor_id']).compact
    )
    result = Outbound::PlaygroundDeliveryPolicy.with(policy) do
      with_actor { executor.execute(action['tool'], action['arguments'], prepared: prepared) }
    end
    action['status'] = Captain::ToolResult.error?(result) ? 'failed' : 'completed'
    action['result'] = result.to_s.first(12_000)
    { action_id: id, result: result, success: action['status'] == 'completed', delivered: false }
  rescue StandardError
    action['status'] = 'failed' if action && action['status'] == 'executing'
    raise
  end

  private

  # The executor of the agent the preview was made for. A preview without an actor (made before it was recorded) belongs to the
  # session's own agent.
  def executor_for(actor_id)
    return @executor if actor_id.blank? || actor_id.to_i == @session.assistant.id

    Captain::Playground::RealToolExecutor.new(@session.acting_as(actor_id.to_i))
  end

  def with_actor
    previous = Current.executed_by
    Current.executed_by = @session.user
    yield
  ensure
    Current.executed_by = previous
  end

  def fingerprint(value)
    Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
  end

  def canonical(value)
    case value
    when Hash then value.deep_stringify_keys.sort.to_h.transform_values { |item| canonical(item) }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end
end
