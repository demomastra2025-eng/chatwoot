# frozen_string_literal: true

# The durable reply history is the source of truth. Reconcile in send-time order under the
# contact lock: a delayed feedback can change an old allocation, never displace the current one.
class Accounts::AiDialogWindow
  WINDOW_KEY = Accounts::MonthlyAiUsageService::CONVERSATION_WINDOW_KEY
  attr_reader :period_deltas

  def initialize(contact, at:)
    @contact = contact
    @at = at
    @state = Accounts::AiDialogState.find_or_initialize_by(account_id: contact.account_id, contact_id: contact.id)
  end

  def import_legacy_events!
    return if @state.persisted?

    windows = @contact.conversations.where(account_id: @contact.account_id).pluck(:additional_attributes)
                      .filter_map { |attrs| attrs.to_h[WINDOW_KEY] }.select { |window| window.is_a?(Hash) }
    import_source_ids!(windows)
    seeds = windows.filter_map do |window|
      started = parse_time(window['started_at'])
      count = window['replies_count'].to_i.clamp(0, Accounts::MonthlyAiUsageService::DIALOG_WINDOW_MAX_REPLIES)
      { 'at' => started.iso8601(6), 'count' => count } if started && count.positive?
    end
    @state.state = { 'legacy_seeds' => seeds }
  end

  def snapshot
    import_legacy_events!
    @state.state.deep_dup
  end

  def record_reply!
    previous = @state.state.fetch('period_counts', {})
    windows = Accounts::AiDialogTimeline.new(timeline).windows
    counts = dialog_counts(windows)
    @period_deltas = (previous.keys | counts.keys).index_with { |key| counts.fetch(key, 0) - previous.fetch(key, 0) }
    @state.state = @state.state.merge('windows' => windows, 'period_counts' => counts).merge(windows.last || {})
    @state.save!
    @period_deltas.values.sum.positive?
  end

  private

  def dialog_counts(windows)
    windows.reject { |window| window['legacy'] }.map { |window| period(window['started_at']) }.tally
  end

  def timeline
    scope = Accounts::AiUsageEvent.where(account_id: @contact.account_id, contact_id: @contact.id,
                                         bucket: Accounts::MonthlyAiUsageService::AI_DIALOGS_MONTHLY_KEY).where('quantity > 0')
    replies = scope.order(:occurred_at, :id).pluck(:occurred_at).map { |at| [at, 1, false] }
    seeds = Array(@state.state['legacy_seeds']).map { |seed| [parse_time(seed['at']), seed['count'], true] }
    (seeds + replies).sort_by(&:first)
  end

  def import_source_ids!(windows)
    events = windows.flat_map { |window| Array(window['message_ids']) }.compact_blank.uniq.map do |id|
      { account_id: @contact.account_id, contact_id: @contact.id, event_key: "message:#{id}",
        bucket: Accounts::MonthlyAiUsageService::AI_DIALOGS_MONTHLY_KEY, occurred_at: @at, quantity: 0 }
    end
    Accounts::AiUsageEvent.insert_all(events, unique_by: [:account_id, :event_key]) if events.any? # rubocop:disable Rails/SkipsModelValidations
  end

  def parse_time(raw)
    Time.iso8601(raw.to_s)
  rescue ArgumentError
    nil
  end

  def period(raw)
    parse_time(raw).getlocal(Accounts::MonthlyAiUsageService::ALMATY_OFFSET).strftime('%Y-%m')
  end
end
