# frozen_string_literal: true

# Monthly (Asia/Almaty, UTC+5) metering for:
# 1. Patient AI dialogs (`captain_ai_dialogs`): 1 dialog = up to 24 hours OR up to 20 AI replies in a conversation.
# 2. AI-ROP call analysis minutes (`call_analysis_minutes`): per-second accumulation; calls < 5s and unanswered calls are excluded.
#
# Exceeding a positive monthly quota is strictly non-blocking: overages are billed at 30 KZT/dialog and 10 KZT/min.
class Accounts::MonthlyAiUsageService
  ALMATY_OFFSET = Accounts::Plans::ASTANA_OFFSET
  AI_DIALOGS_MONTHLY_KEY = 'captain_ai_dialogs_monthly'
  CALL_SECONDS_MONTHLY_KEY = 'call_analysis_seconds_monthly'
  CONVERSATION_WINDOW_KEY = 'captain_ai_dialog_window'

  DIALOG_WINDOW_DURATION = 24.hours
  DIALOG_WINDOW_MAX_REPLIES = 20
  MIN_BILLABLE_CALL_SECONDS = 5

  OVERAGE_AI_DIALOG_KZT = 30
  OVERAGE_CALL_MINUTE_KZT = 10
  MAX_RETENTION_MONTHS = 6
  MAX_TRACKED_MESSAGE_IDS = 25

  MONTHLY_BUCKET_SQL = <<~SQL.squish.freeze
    custom_attributes = jsonb_set(
      CASE
        WHEN jsonb_typeof(COALESCE(custom_attributes, '{}'::jsonb) -> :bucket) = 'object'
        THEN COALESCE(custom_attributes, '{}'::jsonb)
        ELSE jsonb_set(COALESCE(custom_attributes, '{}'::jsonb), ARRAY[:bucket], '{}'::jsonb, true)
      END,
      ARRAY[:bucket, :period],
      to_jsonb(
        COALESCE(
          CASE
            WHEN jsonb_typeof(COALESCE(custom_attributes, '{}'::jsonb) #> ARRAY[:bucket, :period]) = 'number'
            THEN (custom_attributes #>> ARRAY[:bucket, :period])::bigint
            ELSE 0
          END,
          0
        ) + :delta
      ),
      true
    )
  SQL

  PRUNE_STALE_KEYS_SQL = <<~SQL.squish.freeze
    custom_attributes = jsonb_set(
      COALESCE(custom_attributes, '{}'::jsonb),
      ARRAY[:bucket],
      COALESCE(custom_attributes -> :bucket, '{}'::jsonb) - ARRAY(SELECT jsonb_array_elements_text(:stale_json::jsonb)),
      true
    )
  SQL

  def initialize(account)
    @account = account
  end

  def period_key(at = Time.current)
    at.to_time.getlocal(ALMATY_OFFSET).strftime('%Y-%m')
  end

  def ai_dialogs_consumed(at: Time.current)
    monthly_value(AI_DIALOGS_MONTHLY_KEY, period_key(at))
  end

  def call_analysis_seconds_consumed(at: Time.current)
    monthly_value(CALL_SECONDS_MONTHLY_KEY, period_key(at))
  end

  def call_analysis_minutes_consumed(at: Time.current)
    seconds = call_analysis_seconds_consumed(at: at)
    seconds.positive? ? (seconds / 60.0).ceil : 0
  end

  # Records one outbound AI reply in a conversation. Opens a new billable 24h / 20-reply dialog window when none is active.
  # Returns :new_dialog when the monthly dialog counter was incremented, :existing_dialog when absorbed into the active window,
  # or :duplicate when message_id was already recorded.
  def record_ai_dialog_reply!(conversation, message_id: nil, at: Time.current)
    return false unless @account && conversation

    msg_key = message_id.to_s.presence
    outcome = :existing_dialog
    timestamp = at.to_time.getlocal(ALMATY_OFFSET).iso8601
    Conversation.transaction do
      locked = Conversation.lock.find(conversation.id)
      attrs = (locked.additional_attributes || {}).deep_dup
      window = attrs[CONVERSATION_WINDOW_KEY]
      if duplicate_reply_message?(window, msg_key)
        outcome = :duplicate
      else
        attrs[CONVERSATION_WINDOW_KEY], opened_new_window = next_window_state(window, at, timestamp, msg_key)
        # rubocop:disable Rails/SkipsModelValidations
        locked.update_columns(additional_attributes: attrs)
        # rubocop:enable Rails/SkipsModelValidations
        conversation.additional_attributes = attrs
        increment_monthly_bucket!(AI_DIALOGS_MONTHLY_KEY, period_key(at), 1) if opened_new_window
        outcome = opened_new_window ? :new_dialog : :existing_dialog
      end
    end
    outcome
  end

  # Records analyzed call seconds when the call was answered and lasted at least 5 seconds.
  def record_call_analysis!(duration_seconds:, unanswered: false, at: Time.current)
    return false unless @account
    return false if unanswered

    seconds = parse_seconds(duration_seconds)
    return false if seconds.nil? || !seconds.finite? || seconds < MIN_BILLABLE_CALL_SECONDS

    increment_monthly_bucket!(CALL_SECONDS_MONTHLY_KEY, period_key(at), seconds.round)
    true
  end

  private

  def duplicate_reply_message?(window, msg_key)
    msg_key.present? && window.is_a?(Hash) && Array(window['message_ids']).include?(msg_key)
  end

  def next_window_state(window, at, timestamp, msg_key)
    current = window.is_a?(Hash) ? window : {}
    tracked_ids = append_message_id(current['message_ids'], msg_key)
    if active_dialog_window?(current, at)
      state = { 'started_at' => current['started_at'], 'replies_count' => current['replies_count'].to_i + 1 }
      state['message_ids'] = tracked_ids if tracked_ids.any?
      [state, false]
    else
      state = { 'started_at' => timestamp, 'replies_count' => 1 }
      state['message_ids'] = tracked_ids if tracked_ids.any?
      [state, true]
    end
  end

  def append_message_id(existing_ids, msg_key)
    ids = Array(existing_ids).map(&:to_s).reject(&:blank?)
    ids << msg_key if msg_key.present?
    ids.last(MAX_TRACKED_MESSAGE_IDS)
  end

  def monthly_value(bucket_key, period)
    bucket = @account.custom_attributes.to_h[bucket_key]
    return 0 unless bucket.is_a?(Hash)

    value = bucket[period].to_i
    value.positive? ? value : 0
  end

  def active_dialog_window?(window, at)
    started_at = parse_time(window['started_at'])
    replies_count = window['replies_count'].to_i
    return false unless started_at && replies_count.positive? && replies_count < DIALOG_WINDOW_MAX_REPLIES

    elapsed = at.to_time - started_at
    !elapsed.negative? && elapsed < DIALOG_WINDOW_DURATION
  end

  def parse_time(raw)
    return if raw.blank?

    Time.iso8601(raw.to_s)
  rescue ArgumentError
    Time.zone.parse(raw.to_s)
  end

  def parse_seconds(raw)
    return raw.to_f if raw.is_a?(Numeric)
    return if raw.blank?

    Float(raw.to_s, exception: false)
  end

  # rubocop:disable Rails/SkipsModelValidations
  def increment_monthly_bucket!(bucket_key, period, delta)
    return unless delta.to_i.positive?

    sql = Arel.sql(
      ActiveRecord::Base.sanitize_sql_array([MONTHLY_BUCKET_SQL, { bucket: bucket_key, period: period, delta: delta.to_i }])
    )
    Account.where(id: @account.id).update_all(sql)
    refresh_and_prune_bucket!(bucket_key)
  end

  def refresh_and_prune_bucket!(bucket_key)
    fresh = Account.where(id: @account.id).pick(:custom_attributes).to_h
    bucket = fresh[bucket_key]
    if bucket.is_a?(Hash) && bucket.size > MAX_RETENTION_MONTHS
      stale_keys = bucket.keys.sort[0...-MAX_RETENTION_MONTHS]
      if stale_keys.any?
        sql = Arel.sql(
          ActiveRecord::Base.sanitize_sql_array([PRUNE_STALE_KEYS_SQL, { bucket: bucket_key, stale_json: stale_keys.to_json }])
        )
        Account.where(id: @account.id).update_all(sql)
        fresh = Account.where(id: @account.id).pick(:custom_attributes).to_h
      end
    end
    @account.custom_attributes = fresh
  end
  # rubocop:enable Rails/SkipsModelValidations
end
