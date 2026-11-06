# frozen_string_literal: true

# Aggregate counts only. No messages, candidate digests, provider answers or secrets.
# rubocop:disable Metrics/ModuleLength, Style/GlobalVars
module Llm::PiiFeedbackMetrics
  PREFIX = 'llm:pii_feedback:stats:v3'
  FIELDS = %w[
    text_checks checks_with_masked_pii masked_name_tokens masked_phone_tokens masked_iin_tokens
    eligible_checks skipped_no_candidates skipped_policy skipped_duplicate skipped_rate
    admission_grants enqueue_failed audit_attempts audit_completed diagnostic_audits_completed decider_clean_predictions
    decider_suspected_misses decider_unknown_predictions new_quarantined_names
    audit_failed audit_unavailable verified_name_promotions verified_quarantine_promotions
    verified_boundary_unmasked_names
  ].freeze
  LUA_GUARDS = <<~LUA
    local function expect_type(key, expected)
      local actual = redis.call('TYPE', key).ok
      if actual ~= 'none' and actual ~= expected then error('PII feedback key type') end
    end
    local function safe_integer(value)
      return not value or (string.len(value) <= 15 and (value == '0' or string.match(value, '^[1-9][0-9]*$')))
    end
    local function validate_delta(value)
      local number = tonumber(value)
      if not number or number < 0 or number > 10000 or number ~= math.floor(number) then error('PII feedback delta') end
    end
  LUA
  LUA_HELPER = (LUA_GUARDS + <<~LUA).freeze
    for _, key in ipairs({KEYS[#KEYS-1], KEYS[#KEYS]}) do
      expect_type(key, 'hash')
      for _, field in ipairs({#{FIELDS.map { |field| "'#{field}'" }.join(', ')}}) do
        if not safe_integer(redis.call('HGET', key, field)) then error('PII feedback counter') end
      end
    end
    local function count(field, delta)
      if tonumber(delta) > 0 then
        for _, key in ipairs({KEYS[#KEYS-1], KEYS[#KEYS]}) do
          redis.call('HINCRBY', key, field, tonumber(delta))
          redis.call('HSETNX', key, 'observed_since', ARGV[#ARGV])
        end
      end
    end
  LUA
  INCREMENT_SCRIPT = (LUA_HELPER + <<~LUA).freeze
    for i = 1, #ARGV-1, 2 do validate_delta(ARGV[i+1]) end
    for i = 1, #ARGV-1, 2 do count(ARGV[i], ARGV[i+1]) end
    return 1
  LUA
  @mock_mutex = Mutex.new

  module_function

  def account_id(value)
    text = value.to_s
    text.to_i if text.match?(/\A[1-9][0-9]*\z/)
  end

  def keys(account_id)
    ["#{PREFIX}:global", "#{PREFIX}:#{self.account_id(account_id) || 'accountless'}"]
  end

  def with_store(&)
    raise 'PII metrics store unavailable' unless defined?($alfred) && $alfred.respond_to?(:with)

    $alfred.with(&)
  end

  def eval_script(connection, script, keys:, argv:)
    if connection.respond_to?(:call_with_namespace)
      connection.call_with_namespace(:eval, script, keys: keys, argv: argv)
    else
      connection.eval(script, keys: keys, argv: argv)
    end
  end

  def mock?(connection)
    defined?(::MockRedis) && (connection.instance_of?(::MockRedis) ||
      (connection.respond_to?(:redis) && connection.redis.instance_of?(::MockRedis)))
  end

  # Test-only equivalent; production always uses Redis Lua across processes.
  def mock_atomic(connection)
    @mock_mutex.synchronize { yield connection }
  end

  def mock_count(connection, keys, counts, timestamp)
    keys.each do |key|
      counts.each do |field, delta|
        next unless delta.to_i.positive?

        connection.hincrby(key, field.to_s, delta.to_i)
        connection.hsetnx(key, 'observed_since', timestamp)
      end
    end
  end

  def increment(account_id, counts)
    counts = counts.stringify_keys.slice(*FIELDS).select { |_, value| value.to_i.positive? }
    return true if counts.empty?

    timestamp = Time.now.utc.iso8601
    with_store do |connection|
      if mock?(connection)
        mock_atomic(connection) { mock_count(connection, keys(account_id), counts, timestamp) }
      else
        eval_script(connection, INCREMENT_SCRIPT, keys: keys(account_id), argv: counts.to_a.flatten + [timestamp])
      end
    end
    true
  rescue StandardError
    false
  end

  def ratio(counters, numerator, denominator)
    counters[denominator].positive? ? counters[numerator].fdiv(counters[denominator]) : nil
  end

  def coverage(counters)
    {
      completed_per_eligible_check: ratio(counters, 'audit_completed', 'eligible_checks'),
      admitted_per_eligible_check: ratio(counters, 'admission_grants', 'eligible_checks'),
      completed_per_admission_grant: ratio(counters, 'audit_completed', 'admission_grants')
    }
  end

  def validate_snapshot!(raw)
    raise 'Invalid PII feedback counters' unless FIELDS.all? { |field| raw[field].nil? || raw[field].match?(/\A(?:0|[1-9][0-9]{0,15})\z/) }
    return unless raw['observed_since'] && !raw['observed_since'].match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/)

    raise 'Invalid PII feedback observation time'
  end

  # Explicit global opt-in prevents an omitted/invalid account exposing other tenants.
  def summary(account_id: nil, global: false) # rubocop:disable Metrics/MethodLength
    raise ArgumentError, 'A positive account_id or explicit global: true is required' unless global || self.account_id(account_id)

    key = global ? keys(nil).first : keys(account_id).last
    raw = with_store { |connection| connection.hgetall(key) }
    validate_snapshot!(raw)

    counters = FIELDS.index_with { |field| raw[field].to_i }
    {
      status: raw.empty? ? :not_observed : :available,
      collection_enabled: Llm::PiiShadowAuditor.shadow_audit_enabled?,
      observed_since: raw['observed_since'],
      unit: 'text checks; unique placeholders per check; audit attempts/completions; name promotions',
      counters: counters,
      **coverage(counters),
      confirmed_false_negatives: nil, rejected_predictions: nil, precision: nil, recall: nil,
      limitations: 'No gold labels. Boundary observations confirm identity and an unmasked occurrence, not patient attribution. ' \
                   'Only successful Redis writes while enabled are observed; OFF periods/outages are unobserved. ' \
                   'Retries count attempts; completion dedup lasts one hour. Direct diagnostic completions are separate and excluded from coverage.'
    }
  rescue ArgumentError
    raise
  rescue StandardError
    { status: :unavailable, counters: nil, completed_per_eligible_check: nil,
      confirmed_false_negatives: nil, rejected_predictions: nil, precision: nil, recall: nil }
  end
end
# rubocop:enable Metrics/ModuleLength, Style/GlobalVars
