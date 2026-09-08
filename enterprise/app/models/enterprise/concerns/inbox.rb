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
    validate :ensure_within_channel_limit, on: :create
  end

  private

  def ensure_within_channel_limit
    return if account.blank?

    if call_channel?
      return if account.call_channels_count < allowed_channel_limit(:call_inboxes)

      errors.add(:base, 'Account call channel limit exceeded')
    else
      return if account.text_channels_count < allowed_channel_limit(:inboxes)

      errors.add(:base, 'Account channel limit exceeded')
    end
  end

  def allowed_channel_limit(key)
    account.usage_limits.fetch(key, ChatwootApp.max_limit).to_i
  end

  def call_channel?
    channel_type == Enterprise::Account::PlanUsageAndLimits::CALL_CHANNEL_TYPE
  end
end
