require 'digest'

class Captain::Playground::ActionApproval
  MAX_PREVIEWS = 20

  def initialize(session)
    @session = session
    @executor = Captain::Playground::RealToolExecutor.new(session)
  end

  def preview(tool_id, arguments)
    raise ArgumentError, 'Changing real data is disabled' unless @session.write_enabled?

    prepared = @executor.prepare(tool_id, arguments)
    current = @session.permissions
    raise ArgumentError, 'Changing real data is disabled' unless current['read'] == true && current['write'] == true
    action = {
      'tool' => tool_id.to_s, 'arguments' => prepared[:arguments].deep_stringify_keys,
      'target' => prepared[:target].deep_stringify_keys, 'generation' => current['generation'],
      'binding' => @session.context_reference.stringify_keys
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
    prepared = @executor.prepare(action['tool'], action['arguments'])
    current = @session.permissions
    unless current['read'] == true && current['write'] == true && current['generation'] == action['generation']
      raise ArgumentError, 'The real-action confirmation was revoked'
    end
    unless prepared[:target].deep_stringify_keys == action['target'] && fingerprint(action.slice('tool', 'arguments', 'target', 'generation', 'binding')) == digest
      raise ArgumentError, 'The target or payload changed; review a new preview'
    end

    # A replay cannot repeat a partially completed domain or provider write.
    action['status'] = 'executing'
    action['confirmed_at'] = Time.current.iso8601
    @session.save!
    policy = Outbound::PlaygroundDeliveryPolicy.issue(
      @session.context_reference.merge(mode: 'workspace', run_id: SecureRandom.uuid, delivery_enabled: false,
                                       action_id: action['id'], action_digest: digest, generation: action['generation'],
                                       tool: action['tool'], arguments: action['arguments'], target: action['target'])
    )
    result = Outbound::PlaygroundDeliveryPolicy.with(policy) do
      with_actor { @executor.execute(action['tool'], action['arguments'], prepared: prepared) }
    end
    action['status'] = Captain::ToolResult.error?(result) ? 'failed' : 'completed'
    action['result'] = result.to_s.first(12_000)
    { action_id: id, result: result, success: action['status'] == 'completed', delivered: false }
  rescue StandardError
    action['status'] = 'failed' if action && action['status'] == 'executing'
    raise
  end

  private

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
