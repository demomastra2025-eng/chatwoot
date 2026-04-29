# == Schema Information
#
# Table name: captain_inboxes
#
#  id                   :bigint           not null, primary key
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  captain_assistant_id :bigint           not null
#  inbox_id             :bigint           not null
#
# Indexes
#
#  index_captain_inboxes_on_captain_assistant_id               (captain_assistant_id)
#  index_captain_inboxes_on_captain_assistant_id_and_inbox_id  (captain_assistant_id,inbox_id) UNIQUE
#  index_captain_inboxes_on_inbox_id                           (inbox_id)
#
class CaptainInbox < ApplicationRecord
  belongs_to :captain_assistant, class_name: 'Captain::Assistant'
  belongs_to :inbox

  validates :inbox_id, uniqueness: true

  after_commit :invalidate_inbox_cache, on: %i[create update destroy]
  after_commit :sync_voice_routing_policy!, on: %i[create update]
  after_commit :clear_voice_routing_policy, on: :destroy

  def self.sync_voice_routing_policies!
    includes(inbox: :channel).find_each(&:sync_voice_routing_policy!)
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
