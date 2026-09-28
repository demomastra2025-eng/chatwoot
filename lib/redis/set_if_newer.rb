class Redis::SetIfNewer
  SCRIPT = <<~LUA.freeze
    local previous = redis.call('GET', KEYS[1])
    if previous then
      local valid, state = pcall(cjson.decode, previous)
      if valid and type(state) == 'table' and tonumber(state[ARGV[2]]) then
        if tonumber(state[ARGV[2]]) > tonumber(ARGV[3]) then return 0 end
      end
    end
    redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[4])
    return 1
  LUA

  def self.call(connection_pool, key, value, **options)
    connection_pool.with do |connection|
      next set_mock(connection, key, value, options) if defined?(::MockRedis) && connection.redis.instance_of?(::MockRedis)

      arguments = [value, options.fetch(:version_key), options.fetch(:version), options.fetch(:ex)]
      connection.call_with_namespace(:eval, SCRIPT, keys: [key], argv: arguments)
    end
  end

  def self.set_mock(connection, key, value, options)
    previous = parse_previous(connection.get(key))
    return 0 if previous.is_a?(Hash) && previous.fetch(options.fetch(:version_key), 0).to_i > options.fetch(:version)

    connection.set(key, value, ex: options.fetch(:ex))
    1
  end

  def self.parse_previous(raw_state)
    JSON.parse(raw_state.to_s)
  rescue JSON::ParserError
    nil
  end
  private_class_method :parse_previous
  private_class_method :set_mock
end
