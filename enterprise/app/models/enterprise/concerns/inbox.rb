module Enterprise::Concerns::Inbox
  extend ActiveSupport::Concern

  included do
    has_one :captain_inbox, dependent: :destroy, class_name: 'CaptainInbox'
    has_one :captain_assistant,
            through: :captain_inbox,
            class_name: 'Captain::Assistant'
    has_many :inbox_capacity_limits, dependent: :destroy
    has_many :calls, dependent: :destroy_async
    has_one :telephony_number_binding, dependent: :destroy, class_name: '::Telephony::NumberBinding'
    has_many :telephony_sip_profiles, dependent: :destroy, class_name: '::Telephony::SipProfile'
    before_validation :lock_account_for_channel_limits, on: :create
    validate :ensure_within_channel_limit, on: :create
  end

  private

  def ensure_within_channel_limit
    return if account.blank?

    if call_channel?
      return if account.call_channels_count < allowed_channel_limit(:call_inboxes)

      errors.add(:base, 'Account call channel limit exceeded')
    else
      errors.add(:base, 'Account channel limit exceeded') if account.text_channels_count >= allowed_channel_limit(:inboxes)
      errors.add(:base, 'Account main channel limit exceeded') if main_channel_limit_exceeded?
    end
  end

  def lock_account_for_channel_limits
    account.lock! if account&.persisted?
  end

  def allowed_channel_limit(key)
    account.usage_limits.fetch(key, ChatwootApp.max_limit).to_i
  end

  def call_channel?
    channel_type == Enterprise::Account::PlanUsageAndLimits::CALL_CHANNEL_TYPE
  end

  def main_channel_limit_exceeded?
    main_channel? && account.main_channels_count >= allowed_channel_limit(:non_web_inboxes)
  end

  def main_channel?
    Enterprise::Account::PlanUsageAndLimits::MAIN_CHANNEL_TYPES.include?(channel_type)
  end
end
