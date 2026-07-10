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
    return allowed_result(inbox) if inbox.blank? || !inbox.working_hours_enabled?

    schedule = inbox.working_hours.to_a
    return allowed_result(inbox) if schedule.blank?

    current_time = now.in_time_zone(inbox.timezone.presence || 'UTC')
    return allowed_result(inbox) if open_at?(current_time, schedule)

    next_open_at, close_at = next_open_window(current_time, schedule)
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

  def open_at?(time, schedule)
    working_hour = schedule_for(time, schedule)
    return false if working_hour.blank? || working_hour.closed_all_day?
    return true if working_hour.open_all_day?

    time >= open_time_for(time, working_hour) && time <= close_time_for(time, working_hour)
  end

  def next_open_window(current_time, schedule)
    8.times do |offset|
      candidate_day = current_time.to_date + offset
      working_hour = schedule.find { |entry| entry.day_of_week == candidate_day.wday }
      next if working_hour.blank? || working_hour.closed_all_day?

      open_at = time_on_day(current_time, candidate_day, working_hour.open_hour || 0, working_hour.open_minutes || 0)
      close_at = working_hour.open_all_day? ? time_on_day(current_time, candidate_day, 23, 59, 59) : close_time_for(open_at, working_hour)
      next if offset.zero? && current_time > close_at
      next if offset.zero? && current_time >= open_at && !working_hour.open_all_day?

      return [open_at, close_at]
    end

    nil
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

  def schedule_for(time, schedule)
    schedule.find { |entry| entry.day_of_week == time.to_date.wday }
  end

  def open_time_for(time, working_hour)
    time_on_day(time, time.to_date, working_hour.open_hour || 0, working_hour.open_minutes || 0)
  end

  def close_time_for(time, working_hour)
    time_on_day(time, time.to_date, working_hour.close_hour || 23, working_hour.close_minutes || 59, 59)
  end

  def time_on_day(reference_time, date, hour, minute, second = 0)
    reference_time.change(year: date.year, month: date.month, day: date.day, hour: hour, min: minute, sec: second)
  end
end
