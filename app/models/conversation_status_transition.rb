# == Schema Information
#
# Table name: conversation_status_transitions
#
#  id              :bigint           not null, primary key
#  actor_type      :string
#  from_status     :string           not null
#  metadata        :jsonb            not null
#  reason          :string
#  source          :string           default("manual"), not null
#  to_status       :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  actor_id        :bigint
#  conversation_id :bigint           not null
#
# Indexes
#
#  idx_conv_status_transitions_on_account_conversation_created  (account_id,conversation_id,created_at)
#  idx_conv_status_transitions_on_account_status_created        (account_id,to_status,created_at)
#  index_conversation_status_transitions_on_account_id          (account_id)
#  index_conversation_status_transitions_on_actor               (actor_type,actor_id)
#  index_conversation_status_transitions_on_conversation_id     (conversation_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (conversation_id => conversations.id)
#
class ConversationStatusTransition < ApplicationRecord
  VALID_SOURCES = %w[manual api bulk_action communication_thread macro automation captain copilot system contact auto_resolve].freeze

  belongs_to :account
  belongs_to :conversation
  belongs_to :actor, polymorphic: true, optional: true

  validates :from_status, :to_status, presence: true, inclusion: { in: ->(_record) { Conversation.statuses.keys } }
  validates :source, presence: true, inclusion: { in: VALID_SOURCES }
  validates :reason, length: { maximum: 255 }, allow_blank: true
  validates :metadata, jsonb_attributes_length: true

  before_validation :normalize_values

  private

  def normalize_values
    self.from_status = from_status.to_s.strip.presence
    self.to_status = to_status.to_s.strip.presence
    self.reason = reason.to_s.strip.presence
    self.source = source.to_s.strip.presence || 'manual'
    self.metadata = {} if metadata.blank?
  end
end
