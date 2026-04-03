require 'digest'

class Captain::ToolExecutionIdempotency
  DEFAULT_EXPIRY = 5.minutes

  class << self
    def fetch_record(...)
      new(...).fetch_record
    end

    def store_record(assistant:, tool_id:, params:, scope: {}, record:)
      new(
        assistant: assistant,
        tool_id: tool_id,
        params: params,
        scope: scope
      ).store_record(record)
    end
  end

  def initialize(assistant:, tool_id:, params:, scope: {})
    @assistant = assistant
    @tool_id = tool_id
    @params = (params || {}).deep_stringify_keys
    @scope = (scope || {}).deep_stringify_keys
  end

  def fetch_record
    payload = Rails.cache.read(cache_key)
    return nil unless payload.is_a?(Hash)

    record_class = payload['class_name'].to_s.safe_constantize
    return nil if record_class.blank?

    record_class.find_by(id: payload['record_id'])
  rescue StandardError
    nil
  end

  def store_record(record)
    return record unless record.respond_to?(:id)

    Rails.cache.write(
      cache_key,
      {
        'class_name' => record.class.name,
        'record_id' => record.id
      },
      expires_in: DEFAULT_EXPIRY
    )
    record
  rescue StandardError
    record
  end

  private

  def cache_key
    [
      'captain_tool_execution',
      'idempotency',
      @assistant.account_id,
      @assistant.id,
      @tool_id,
      scope_digest,
      params_digest
    ].join(':')
  end

  def scope_digest
    Digest::SHA256.hexdigest(JSON.generate(serializable_hash(@scope)))
  end

  def params_digest
    Digest::SHA256.hexdigest(JSON.generate(serializable_hash(@params)))
  end

  def serializable_hash(hash)
    hash.sort.to_h.transform_values do |value|
      value.respond_to?(:as_json) ? value.as_json : value
    end
  end
end
