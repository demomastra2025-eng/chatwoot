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
    return if account.blank?
    return unless account.main_channels_count >= allowed_channel_limit

    errors.add(:base, 'Account main channel limit exceeded')
  end

  def allowed_channel_limit
    allowed = account.usage_limits.fetch(:non_web_inboxes, ChatwootApp.max_limit).to_i
    return ChatwootApp.max_limit.to_i if allowed >= ChatwootApp.max_limit.to_i
    return ChatwootApp.max_limit.to_i unless main_channel?

    allowed
  end

  def main_channel?
    Enterprise::Account::PlanUsageAndLimits::MAIN_CHANNEL_TYPES.include?(channel_type)
  end
end
