class Conversations::ReopenSnoozedConversationsJob < ApplicationJob
  queue_as :low

  # One person wakes in one conversation, see Conversations::SnoozeExpiryService.
  def perform
    Conversation.where(status: :snoozed).where(snoozed_until: 3.days.ago..Time.current).find_each(batch_size: 100) do |conversation|
      Conversations::SnoozeExpiryService.new(conversation).perform
    end
  end
end
