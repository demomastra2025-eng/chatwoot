# frozen_string_literal: true

# Monthly (Asia/Almaty, UTC+5) metering for:
# 1. Patient AI dialogs (`captain_ai_dialogs`): 1 dialog = up to 24 hours OR up to 20 AI replies per contact, across channels within an account.
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

  # One entry point for provider acknowledgements and manager-sent suggestion feedback.
  # `sent` alone is the Message default, so external channels also need a provider id/receipt.
  def record_sent_message!(message)
    return false unless source_owned?(message)
    return false unless public_reply?(message)

    # The provider can hold an object loaded before suggestion feedback added its provenance.
    # Read the persisted row under the save transaction rather than trusting that object's JSON.
    sent = Message.find_by(id: message.id, account_id: @account.id)
    return false unless sent && acknowledged?(sent)

    return false unless ai_reply?(sent)
    return record_historical_message!(sent) if sent.ai_usage_version.nil?

    record_ai_dialog_reply!(sent.conversation, message_id: sent.id, at: sent.ai_usage_sent_at)
  end

  # Internal accounting boundary; callers must supply the persisted message identity.
  def record_ai_dialog_reply!(conversation, message_id:, at: Time.current)
    return false unless source_owned?(conversation)
    return false if message_id.blank?

    contact = @account.contacts.find_by(id: conversation.contact_id)
    return false unless contact

    contact.with_lock do
      window = Accounts::AiDialogWindow.new(contact, at: at)
      window.import_legacy_events!
      next :duplicate unless insert_event!("message:#{message_id}", AI_DIALOGS_MONTHLY_KEY, at, 1, contact.id)

      opened = window.record_reply!
      window.period_deltas.each { |period, delta| increment_monthly_bucket!(AI_DIALOGS_MONTHLY_KEY, period, delta) }
      opened ? :new_dialog : :existing_dialog
    end
  end

  # The source identity is required, even when its caller already holds a row lock.
  # The event and counter participate in the caller's transcript transaction.
  def record_call_analysis!(call:, duration_seconds:, unanswered: false, at: Time.current)
    return false unless source_owned?(call)
    return false if unanswered

    seconds = parse_seconds(duration_seconds)
    return false unless billable_seconds?(seconds)

    Accounts::AiUsageEvent.transaction do
      key = "call:#{call.class.base_class.name}:#{call.id}"
      next false unless insert_event!(key, CALL_SECONDS_MONTHLY_KEY, at, seconds.round)

      increment_monthly_bucket!(CALL_SECONDS_MONTHLY_KEY, period_key(at), seconds.round)
      true
    end
  end

  private

  def record_historical_message!(message)
    insert_event!("message:#{message.id}", AI_DIALOGS_MONTHLY_KEY, message.ai_usage_sent_at || message.created_at, 0)
  end

  def public_reply?(message)
    message.outgoing? && !message.private?
  end

  def source_owned?(source)
    @account.present? && source&.persisted? && source.account_id == @account.id
  end

  def billable_seconds?(seconds)
    seconds.present? && seconds.finite? && seconds >= MIN_BILLABLE_CALL_SECONDS
  end

  def ai_reply?(message)
    attrs = message.additional_attributes.to_h
    attrs['captain_ai_reply'].is_a?(Hash) || attrs['captain_follow_up'].is_a?(Hash) || attrs['captain_ai_suggestion'].is_a?(Hash)
  end

  def acknowledged?(message)
    return false if message.failed?

    message.source_id.present? || message.delivered? || message.read? ||
      message.inbox.channel_type.in?(%w[Channel::WebWidget Channel::Api])
  end

  def insert_event!(key, bucket, at, quantity = 1, contact_id = nil)
    Accounts::AiUsageEvent.insert_all( # rubocop:disable Rails/SkipsModelValidations
      [{ account_id: @account.id, contact_id: contact_id, event_key: key, bucket: bucket, occurred_at: at, quantity: quantity }],
      unique_by: [:account_id, :event_key], returning: [:id]
    ).rows.any?
  end

  def monthly_value(bucket_key, period)
    bucket = @account.custom_attributes.to_h[bucket_key]
    return 0 unless bucket.is_a?(Hash)

    value = bucket[period].to_i
    value.positive? ? value : 0
  end

  def parse_seconds(raw)
    return raw.to_f if raw.is_a?(Numeric)
    return if raw.blank?

    Float(raw.to_s, exception: false)
  end

  # rubocop:disable Rails/SkipsModelValidations
  def increment_monthly_bucket!(bucket_key, period, delta)
    return if delta.to_i.zero?

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
