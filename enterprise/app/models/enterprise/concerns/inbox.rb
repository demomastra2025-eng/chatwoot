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
    validate :ensure_within_non_web_inbox_limit, on: :create
    after_create :enable_workspace_ai_for_new_text_channel
  end

  private

  def enable_workspace_ai_for_new_text_channel
    return if channel_type == 'Channel::Voice'

    main = account.captain_assistants.entry_eligible.find_by(id: account.captain_default_assistant_id)
    return unless main

    CaptainInbox.find_or_create_by!(inbox: self) do |link|
      link.captain_assistant = main
      link.ai_enabled = true
    end
  end

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
