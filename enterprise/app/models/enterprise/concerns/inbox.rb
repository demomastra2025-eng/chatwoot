module Enterprise::Concerns::Inbox
  extend ActiveSupport::Concern

  included do
    has_one :captain_inbox, dependent: :destroy, class_name: 'CaptainInbox'
    has_one :captain_assistant,
            through: :captain_inbox,
            class_name: 'Captain::Assistant'
    has_many :inbox_capacity_limits, dependent: :destroy
    has_one :telephony_number_binding, dependent: :destroy, class_name: '::Telephony::NumberBinding'
    validate :ensure_within_non_web_inbox_limit, on: :create
  end

  private

  def ensure_within_non_web_inbox_limit
    return if web_widget?

    allowed = account.usage_limits.fetch(:non_web_inboxes, ChatwootApp.max_limit).to_i
    return if allowed >= ChatwootApp.max_limit.to_i
    return if account.non_web_inboxes_count < allowed

    errors.add(:base, 'Account non-web inbox limit exceeded')
  end
end
