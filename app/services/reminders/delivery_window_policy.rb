# frozen_string_literal: true

require 'digest'

class Reminders::DeliveryWindowPolicy
  BUFFER_WINDOW = 30.minutes
  RETRY_WHEN_NO_WINDOW = 1.day

  Result = Struct.new(:allowed, :scheduled_at, :inbox, :reason, keyword_init: true) do
    def allowed?
      allowed
    end

    def blocked?
      !allowed
    end
  end

  attr_reader :reminder, :conversation, :now

  def initialize(reminder:, conversation: nil, now: Time.current)
    @reminder = reminder
    @conversation = conversation
    @now = now
  end

  def self.apply!(reminder:, conversation: nil, now: Time.current, processing_claim: reminder.processing_claim_token)
    result = nil
    reminder.with_lock do
      reminder.reload
      result = execution_result(
        reminder: reminder,
        conversation: conversation,
        now: now,
        processing_claim: processing_claim
      )
      reschedule!(reminder, result) if current_execution?(reminder, processing_claim) && result.blocked?
    end
    result
  end

  def self.execution_result(reminder:, conversation:, now:, processing_claim:)
    return new(reminder: reminder, conversation: conversation, now: now).call if current_execution?(reminder, processing_claim)

    Result.new(
      allowed: false,
      scheduled_at: reminder.scheduled_at,
      inbox: conversation&.inbox || reminder.target_inbox,
      reason: 'execution_state_changed'
    )
  end

  def self.current_execution?(reminder, processing_claim)
    reminder.processing? && reminder.processing_claim_token == processing_claim
  end

  def self.reschedule!(reminder, result)
    reminder.update!(
      status: :pending,
      scheduled_at: result.scheduled_at,
      processing_started_at: nil,
      last_error: nil,
      metadata: reschedule_metadata(reminder, result)
    )
  end
  private_class_method :execution_result, :current_execution?, :reschedule!

  def call
    inbox = resolved_inbox
    return allowed_result(inbox) if inbox.blank? || !inbox.account.workspace_working_hours_configured?

    current_time = now.in_time_zone(inbox.account.workspace_working_hours_timezone)
    return allowed_result(inbox) if inbox.account.workspace_open_at?(now)

    next_open_at, close_at = next_open_window(current_time, inbox.account)
    return Result.new(allowed: false, scheduled_at: (now + RETRY_WHEN_NO_WINDOW).utc, inbox: inbox, reason: 'no_working_window') unless next_open_at

    Result.new(
      allowed: false,
      scheduled_at: scheduled_with_buffer(next_open_at, close_at).utc,
      inbox: inbox,
      reason: 'outside_working_hours'
    )
  end

  def self.reschedule_metadata(reminder, result)
    reminder.metadata.to_h.merge(
      'rescheduled_by_working_hours' => true,
      'working_hours_reschedule_reason' => result.reason,
      'working_hours_previous_scheduled_at' => reminder.scheduled_at&.iso8601,
      'working_hours_next_scheduled_at' => result.scheduled_at&.iso8601,
      'working_hours_target_inbox_id' => result.inbox&.id,
      'working_hours_rescheduled_at' => Time.current.iso8601
    ).compact
  end

  private

  def allowed_result(inbox)
    Result.new(allowed: true, scheduled_at: reminder.scheduled_at, inbox: inbox)
  end

  def resolved_inbox
    conversation&.inbox || reminder.target_inbox || reminder.target_conversation&.inbox || reminder.conversation&.inbox
  end

  def next_open_window(current_time, account)
    8.times do |offset|
      candidate_day = current_time.to_date + offset
      next if account.workspace_day_off?(candidate_day)

      day = account.workspace_working_hours_schedule.find { |entry| entry['day_of_week'].to_i == candidate_day.wday }
      next if day.blank? || ActiveModel::Type::Boolean.new.cast(day['closed_all_day'])

      windows_for_day(account, day).each do |start_minute, end_minute|
        open_at = time_on_day(current_time, candidate_day, start_minute)
        close_at = time_on_day(current_time, candidate_day, end_minute)
        next if close_at <= current_time

        return [[open_at, current_time].max, close_at]
      end
    end

    nil
  end

  def windows_for_day(account, day)
    start_minute, end_minute = working_minutes_for(day)
    breaks = account.workspace_break_schedule.select { |entry| entry['days'].include?(day['day_of_week'].to_i) }
    breaks.reduce([[start_minute, end_minute]]) do |windows, entry|
      subtract_break(windows, minute_for_time(entry['start_time']), minute_for_time(entry['end_time']))
    end
  end

  def working_minutes_for(day)
    return [0, 1440] if ActiveModel::Type::Boolean.new.cast(day['open_all_day'])

    [(day['open_hour'].to_i * 60) + day['open_minutes'].to_i,
     (day['close_hour'].to_i * 60) + day['close_minutes'].to_i]
  end

  def subtract_break(windows, break_start, break_end)
    windows.flat_map do |left, right|
      [[left, [right, break_start].min], [[left, break_end].max, right]].select { |first, last| first < last }
    end
  end

  def minute_for_time(value)
    hour, minute = value.split(':').map(&:to_i)
    (hour * 60) + minute
  end

  def scheduled_with_buffer(open_at, close_at)
    buffer_end = [open_at + BUFFER_WINDOW, close_at].min
    jitter_span_seconds = [(buffer_end - open_at).to_i, 0].max
    return open_at if jitter_span_seconds.zero?

    open_at + deterministic_jitter_seconds(jitter_span_seconds).seconds
  end

  def deterministic_jitter_seconds(max_seconds)
    Digest::SHA256.hexdigest("reminder-working-hours-#{reminder.id}").first(8).to_i(16) % (max_seconds + 1)
  end

  def time_on_day(reference_time, date, minutes)
    date += 1 if minutes == 1440
    minutes %= 1440
    reference_time.change(year: date.year, month: date.month, day: date.day,
                          hour: minutes / 60, min: minutes % 60, sec: 0)
  end
end
