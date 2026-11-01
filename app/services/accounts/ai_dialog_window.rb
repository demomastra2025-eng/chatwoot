# frozen_string_literal: true

# One person in one branch. A phone number can belong to several people and is never a metering identity.
class Accounts::AiDialogWindow
  WINDOW_KEY = Accounts::MonthlyAiUsageService::CONVERSATION_WINDOW_KEY

  attr_reader :previous_period

  def initialize(contact, at:)
    @contact = contact
    @at = at
    @state = Accounts::AiDialogState.find_or_initialize_by(account_id: contact.account_id, contact_id: contact.id)
    @window = @state.state if @state.persisted?
  end

  # Lazy, additive cutover under the contact lock: keep billed counters unchanged and import all
  # still-retained source ids before combining the old channel windows. Never rewrite legacy data.
  def import_legacy_events!
    return if @window.is_a?(Hash)

    windows = legacy_windows
    import_source_ids!(windows)
    active = windows.select { |window| within_duration?(window) }
    @window = {
      'started_at' => active.pluck('started_at').min,
      'replies_count' => active.sum { |window| window['replies_count'].to_i }
    }
  end

  def record_reply!
    opened = !active?
    start = opened ? @at : [parse_time(@window['started_at']), @at].min
    last = opened ? @at : [last_reply_at(@window), @at].max
    previous_start = parse_time(@window['started_at'])
    @previous_period = period(previous_start) if !opened && period(previous_start) != period(start)
    @state.state = { 'started_at' => start.iso8601(6), 'last_reply_at' => last.iso8601(6),
                     'replies_count' => opened ? 1 : @window['replies_count'].to_i + 1 }
    @state.save!
    opened
  end

  private

  def import_source_ids!(windows)
    events = windows.flat_map { |window| Array(window['message_ids']) }.compact_blank.uniq.map do |id|
      { account_id: @contact.account_id, event_key: "message:#{id}", bucket: Accounts::MonthlyAiUsageService::AI_DIALOGS_MONTHLY_KEY,
        occurred_at: @at, quantity: 0 }
    end
    Accounts::AiUsageEvent.insert_all(events, unique_by: [:account_id, :event_key]) if events.any? # rubocop:disable Rails/SkipsModelValidations
  end

  def legacy_windows
    @contact.conversations.where(account_id: @contact.account_id)
            .pluck(:additional_attributes).filter_map { |attrs| attrs.to_h[WINDOW_KEY] }.select { |window| window.is_a?(Hash) }
  end

  def active?
    @window['replies_count'].to_i.positive? &&
      @window['replies_count'].to_i < Accounts::MonthlyAiUsageService::DIALOG_WINDOW_MAX_REPLIES && within_duration?(@window)
  end

  def within_duration?(window)
    started = parse_time(window['started_at'])
    return false unless started

    [last_reply_at(window), @at].max - [started, @at].min < Accounts::MonthlyAiUsageService::DIALOG_WINDOW_DURATION
  end

  def last_reply_at(window)
    parse_time(window['last_reply_at']) || parse_time(window['started_at'])
  end

  def parse_time(raw)
    Time.iso8601(raw.to_s)
  rescue ArgumentError
    nil
  end

  def period(time)
    time.getlocal(Accounts::MonthlyAiUsageService::ALMATY_OFFSET).strftime('%Y-%m')
  end
end
