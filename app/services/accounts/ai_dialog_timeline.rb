# frozen_string_literal: true

# A single chronological 24h/20-reply rule, including already paid legacy reply blocks.
class Accounts::AiDialogTimeline
  attr_reader :windows

  def initialize(events)
    @windows = []
    events.each { |at, count, legacy| append(at, count, legacy) }
  end

  private

  def append(at, count, legacy)
    count.times do
      @windows << new_window(at) unless active?(@windows.last, at)
      window = @windows.last
      window['replies_count'] += 1
      window['last_reply_at'] = at.iso8601(6)
      window['legacy'] ||= legacy
    end
  end

  def active?(window, at)
    window && window['replies_count'] < Accounts::MonthlyAiUsageService::DIALOG_WINDOW_MAX_REPLIES &&
      at - Time.iso8601(window['started_at']) < Accounts::MonthlyAiUsageService::DIALOG_WINDOW_DURATION
  end

  def new_window(at)
    { 'started_at' => at.iso8601(6), 'last_reply_at' => at.iso8601(6), 'replies_count' => 0, 'legacy' => false }
  end
end
