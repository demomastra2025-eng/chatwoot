# Puts a value at the front of a JSON array kept under one key (once: an earlier copy of it moves to the front), keeps the first
# `limit` values and sets the expiry, in one atomic step: two writers at the same moment never drop each other's value.
class Redis::JsonListPrepend
  SCRIPT = <<~LUA.freeze
    local raw = redis.call('GET', KEYS[1])
    local list = { ARGV[1] }
    if raw then
      local valid, decoded = pcall(cjson.decode, raw)
      if valid and type(decoded) == 'table' then
        for _, item in ipairs(decoded) do
          if #list >= tonumber(ARGV[2]) then break end
          if type(item) == 'string' and item ~= ARGV[1] then table.insert(list, item) end
        end
      end
    end
    redis.call('SET', KEYS[1], cjson.encode(list), 'EX', ARGV[3])
    return #list
  LUA
  # MockRedis (the test environment) runs no scripts: the same steps under a lock of the process.
  MOCK_LOCK = Mutex.new

  def self.call(connection_pool, key, value, limit:, ex:) # rubocop:disable Naming/MethodParameterName
    connection_pool.with do |connection|
      next prepend_mock(connection, key, value.to_s, limit, ex) if defined?(::MockRedis) && connection.redis.instance_of?(::MockRedis)

      connection.call_with_namespace(:eval, SCRIPT, keys: [key], argv: [value.to_s, limit.to_i, ex.to_i])
    end
  end

  def self.prepend_mock(connection, key, value, limit, seconds)
    MOCK_LOCK.synchronize do
      list = ([value] + (parse(connection.get(key)) - [value])).first(limit.to_i)
      connection.set(key, JSON.generate(list), ex: seconds.to_i)
      list.size
    end
  end

  def self.parse(raw)
    parsed = JSON.parse(raw.to_s)
    parsed.is_a?(Array) ? parsed.grep(String) : []
  rescue JSON::ParserError
    []
  end
  private_class_method :prepend_mock, :parse
end
