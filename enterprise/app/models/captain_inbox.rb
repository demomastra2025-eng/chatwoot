# == Schema Information
#
# Table name: captain_inboxes
#
#  id                          :bigint           not null, primary key
#  auto_reply_mode             :string           default("always"), not null
#  reply_to_open_conversations :boolean          default(FALSE), not null
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  captain_assistant_id        :bigint
#  inbox_id                    :bigint           not null
#
# Indexes
#
#  index_captain_inboxes_on_captain_assistant_id               (captain_assistant_id)
#  index_captain_inboxes_on_captain_assistant_id_and_inbox_id  (captain_assistant_id,inbox_id) UNIQUE
#  index_captain_inboxes_on_inbox_id                           (inbox_id)
#
# The AI settings of one channel. A text channel row holds the channel settings only (ai_enabled, auto_reply_mode,
# reply_to_open_conversations) and no agent: which agent answers is decided by the router among the enabled agents of the workspace
# (see Captain::ChannelScope). A number whose calls the AI answers (a voice channel, or a WhatsApp number with AI voice on) names the
# agent that answers them, because a call has no router.
class CaptainInbox < ApplicationRecord
  VOICE_CHANNEL_TYPE = 'Channel::Voice'.freeze
  WHATSAPP_CHANNEL_TYPE = 'Channel::Whatsapp'.freeze
  AUTO_REPLY_ALWAYS = 'always'.freeze
  AUTO_REPLY_WORKING_HOURS = 'working_hours'.freeze
  AUTO_REPLY_OUTSIDE_WORKING_HOURS = 'outside_working_hours'.freeze
  AUTO_REPLY_MODES = [
    AUTO_REPLY_ALWAYS,
    AUTO_REPLY_WORKING_HOURS,
    AUTO_REPLY_OUTSIDE_WORKING_HOURS
  ].freeze
  DEFAULT_AUTO_REPLY_MODE = AUTO_REPLY_ALWAYS

  # The channels where the AI may answer by itself: a voice number whose agent is enabled, or a text channel that is switched on in a
  # workspace where the AI is on and at least one external agent is enabled (the router picks among the enabled agents).
  scope :enabled_for_runtime, lambda {
    joins(inbox: :account).where(<<~SQL.squish)
      (inboxes.channel_type = 'Channel::Voice' AND EXISTS (
         SELECT 1 FROM captain_assistants voice_agents
         WHERE voice_agents.id = captain_inboxes.captain_assistant_id AND voice_agents.account_id = inboxes.account_id
           AND voice_agents.active = TRUE AND voice_agents.usage_mode = 'external_agent')) OR
      (inboxes.channel_type <> 'Channel::Voice' AND captain_inboxes.ai_enabled = TRUE AND
       COALESCE(accounts.settings #>> '{captain_agent_settings,routing,ai_enabled}', 'true') <> 'false' AND EXISTS (
         SELECT 1 FROM captain_assistants agents
         WHERE agents.account_id = inboxes.account_id AND agents.active = TRUE AND agents.usage_mode = 'external_agent'))
    SQL
  }

  belongs_to :captain_assistant, class_name: 'Captain::Assistant', optional: true
  belongs_to :inbox

  validates :inbox_id, uniqueness: true
  validates :auto_reply_mode, inclusion: { in: AUTO_REPLY_MODES }
  validate :agent_only_on_a_channel_that_takes_calls
  validate :voice_channel_has_an_eligible_agent

  before_validation :set_default_auto_reply_mode

  before_save :lock_voice_assistant_assignment!
  before_destroy :lock_voice_assistant_assignment!
  after_destroy :clear_voice_routing_policy
  after_save :sync_voice_routing_policy!
  after_commit :invalidate_inbox_cache, on: %i[create update destroy]

  def self.sync_voice_routing_policies!
    includes(inbox: :channel).find_each(&:sync_voice_routing_policy!)
  end

  # The AI answers the calls of this number, so the row names the agent for them: a phone number, or a WhatsApp number with AI voice
  # on. Every other channel is text only and names no agent.
  def answers_calls_with_ai?
    return true if voice_channel?

    inbox&.channel_type == WHATSAPP_CHANNEL_TYPE &&
      ActiveModel::Type::Boolean.new.cast(inbox.channel&.provider_config.to_h['ai_voice_enabled']) == true
  end

  def auto_reply_allowed_now?
    return legacy_voice_auto_reply_allowed_now? if inbox&.channel_type == 'Channel::Voice'
    return false unless ai_enabled?

    text_auto_reply_allowed_now?
  end

  def text_auto_reply_allowed_now?
    return false unless inbox.account.captain_ai_enabled?

    mode = inbox.account.captain_reply_time_mode
    return true if mode == AUTO_REPLY_ALWAYS
    return false unless inbox.account.workspace_working_hours_configured?

    workspace_open = inbox.account.workspace_open_at?
    mode == AUTO_REPLY_WORKING_HOURS ? workspace_open : !workspace_open
  end

  def legacy_voice_auto_reply_allowed_now?
    {
      AUTO_REPLY_ALWAYS => true,
      AUTO_REPLY_WORKING_HOURS => inbox&.working_now?,
      AUTO_REPLY_OUTSIDE_WORKING_HOURS => inbox&.out_of_office?
    }.fetch(auto_reply_mode, false) || false
  end

  def sync_voice_routing_policy!
    number_binding = voice_number_binding
    return if number_binding.blank?

    policy = number_binding.routing_policy || number_binding.build_routing_policy(account: inbox.account)
    policy.assign_attributes(
      captain_assistant: captain_assistant,
      ai_enabled: true,
      ai_deployment_mode: Telephony::RoutingPolicy::AI_DEPLOYMENT_ONELINK_MANAGED,
      onelink_ai_app_ref: policy.onelink_ai_app_ref.presence || ENV.fetch('ONELINK_AI_VOICE_APP_REF', nil),
      fallback_mode: synced_fallback_mode(policy, number_binding)
    )
    policy.save!
  end

  private

  def voice_channel?
    inbox&.channel_type == VOICE_CHANNEL_TYPE
  end

  def agent_only_on_a_channel_that_takes_calls
    return if captain_assistant_id.blank?

    unless answers_calls_with_ai?
      errors.add(:captain_assistant, 'is set only on a number whose calls the AI answers: a text channel has no agent')
      return
    end

    errors.add(:captain_assistant, 'must belong to the channel workspace') unless captain_assistant&.account_id == inbox.account_id
  end

  def voice_channel_has_an_eligible_agent
    return unless voice_channel?
    return errors.add(:captain_assistant, :blank) if captain_assistant.blank?
    return errors.add(:captain_assistant, 'must belong to the channel workspace') unless captain_assistant.account_id == inbox.account_id
    return unless new_record? || will_save_change_to_captain_assistant_id?
    return if captain_assistant.entry_eligible?

    errors.add(:captain_assistant, 'must be an active external agent')
  end

  def lock_voice_assistant_assignment!
    Telephony::AiVoice::AssistantAssignmentLock.acquire!(inbox_id)
  end

  def set_default_auto_reply_mode
    self.auto_reply_mode = DEFAULT_AUTO_REPLY_MODE if auto_reply_mode.blank?
  end

  def invalidate_inbox_cache
    return if Current.suppress_runtime_events

    inbox&.account&.update_cache_key(Inbox.name.underscore)
  end

  def clear_voice_routing_policy
    number_binding = voice_number_binding
    return if number_binding&.routing_policy.blank?
    return unless number_binding.routing_policy.captain_assistant_id == captain_assistant_id

    number_binding.routing_policy.update!(captain_assistant: nil, ai_enabled: false)
  end

  def synced_fallback_mode(policy, number_binding)
    return policy.fallback_mode unless policy.fallback_mode == 'reject'
    return 'app' if number_binding.configured_app_ref.present?

    policy.fallback_mode
  end

  def voice_number_binding
    return unless inbox&.channel_type == 'Channel::Voice'

    Telephony::NumberBinding.sync_from_voice_channel!(inbox.channel) if inbox.telephony_number_binding.blank?
    inbox.reload.telephony_number_binding
  end
end
