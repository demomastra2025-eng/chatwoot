class TelegramCalls::Registry
  TTL_SECONDS = 2.hours.to_i

  class << self
    def store_leg!(leg_data)
      data = leg_data.deep_stringify_keys
      key = leg_key(data.fetch('leg_id'))
      write_hash_fields!(key, data)
      data
    end

    def fetch_leg(leg_id)
      return nil if leg_id.blank?

      raw = Redis::Alfred.hgetall(leg_key(leg_id))
      return nil if raw.blank?

      raw.transform_values { |val| parse_json_scalar(val) }
    end

    def update_leg!(leg_id, attributes)
      return nil if leg_id.blank?

      key = leg_key(leg_id)
      return nil unless Redis::Alfred.exists?(key)

      write_hash_fields!(key, attributes.deep_stringify_keys)
      fetch_leg(leg_id)
    end

    def store_source_group!(source_type:, account_id:, source_call_ref:, payload:)
      data = payload.deep_stringify_keys
      meta_key = source_key(source_type: source_type, account_id: account_id, source_call_ref: source_call_ref)
      write_hash_fields!(meta_key, data.except('leg_ids'))
      legs_key = source_legs_key(source_type: source_type, account_id: account_id, source_call_ref: source_call_ref)
      Array.wrap(data['leg_ids']).each { |lid| Redis::Alfred.lpush(legs_key, lid.to_s) }
      Redis::Alfred.expire(legs_key, TTL_SECONDS) if Array.wrap(data['leg_ids']).present?
      fetch_source_group(source_type: source_type, account_id: account_id, source_call_ref: source_call_ref)
    end

    def fetch_source_group(source_type:, account_id:, source_call_ref:)
      meta_key = source_key(source_type: source_type, account_id: account_id, source_call_ref: source_call_ref)
      raw = Redis::Alfred.hgetall(meta_key)
      return nil if raw.blank?

      legs_key = source_legs_key(source_type: source_type, account_id: account_id, source_call_ref: source_call_ref)
      leg_ids = Redis::Alfred.lrange(legs_key, 0, -1).reverse.uniq
      raw.transform_values { |val| parse_json_scalar(val) }.merge('leg_ids' => leg_ids)
    end

    def append_leg_to_source!(source_type:, account_id:, source_call_ref:, leg_id:, group_id: nil)
      meta_key = source_key(source_type: source_type, account_id: account_id, source_call_ref: source_call_ref)
      Redis::Alfred.hsetnx(meta_key, 'group_id', (group_id || SecureRandom.uuid).to_json)
      write_hash_fields!(
        meta_key,
        'source_type' => source_type.to_s, 'account_id' => account_id.to_i, 'source_call_ref' => source_call_ref.to_s
      )
      legs_key = source_legs_key(source_type: source_type, account_id: account_id, source_call_ref: source_call_ref)
      Redis::Alfred.lpush(legs_key, leg_id.to_s)
      Redis::Alfred.expire(legs_key, TTL_SECONDS)
      fetch_source_group(source_type: source_type, account_id: account_id, source_call_ref: source_call_ref)
    end

    def try_claim_source!(source_type:, account_id:, source_call_ref:, leg_id:, user_id:)
      lock_key = claim_key(source_type: source_type, account_id: account_id, source_call_ref: source_call_ref)
      value = { leg_id: leg_id.to_s, user_id: user_id.to_i, claimed_at: Time.current.iso8601 }.to_json
      Redis::Alfred.set(lock_key, value, nx: true, ex: TTL_SECONDS).present?
    end

    def release_claim_source!(source_type:, account_id:, source_call_ref:)
      Redis::Alfred.delete(claim_key(source_type: source_type, account_id: account_id, source_call_ref: source_call_ref))
    end

    def fetch_claim(source_type:, account_id:, source_call_ref:)
      parse_json(Redis::Alfred.get(claim_key(source_type: source_type, account_id: account_id, source_call_ref: source_call_ref)))
    end

    def store_janus_call_map!(account_id:, line_key:, janus_call_id:, call_ref:)
      return if janus_call_id.blank? || call_ref.blank?

      key = janus_map_key(account_id: account_id, line_key: line_key, janus_call_id: janus_call_id)
      Redis::Alfred.set(key, call_ref.to_s, ex: TTL_SECONDS)
    end

    def resolve_janus_call_ref(account_id:, line_key:, janus_call_id:)
      return nil if janus_call_id.blank?

      key = janus_map_key(account_id: account_id, line_key: line_key, janus_call_id: janus_call_id)
      Redis::Alfred.get(key)
    end

    def try_lock_recording_upload!(leg_id)
      return false if leg_id.blank?

      Redis::Alfred.set("telegram_calls:rec_lock:#{leg_id}", '1', nx: true, ex: TTL_SECONDS).present?
    end

    private

    def write_hash_fields!(key, attrs)
      attrs.each { |field, value| Redis::Alfred.hset(key, field.to_s, value.to_json) }
      Redis::Alfred.expire(key, TTL_SECONDS)
    end

    def leg_key(leg_id)
      "telegram_calls:leg:#{leg_id}"
    end

    def source_key(source_type:, account_id:, source_call_ref:)
      "telegram_calls:source:#{source_type}:#{account_id}:#{source_call_ref}"
    end

    def source_legs_key(source_type:, account_id:, source_call_ref:)
      "telegram_calls:source_legs:#{source_type}:#{account_id}:#{source_call_ref}"
    end

    def claim_key(source_type:, account_id:, source_call_ref:)
      "telegram_calls:claim:#{source_type}:#{account_id}:#{source_call_ref}"
    end

    def janus_map_key(account_id:, line_key:, janus_call_id:)
      "telegram_calls:janus_ref:#{account_id}:#{line_key}:#{janus_call_id}"
    end

    def parse_json_scalar(raw)
      JSON.parse(raw)
    rescue JSON::ParserError, TypeError
      raw
    end

    def parse_json(raw)
      return nil if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end
  end
end
