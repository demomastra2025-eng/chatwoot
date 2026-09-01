# frozen_string_literal: true

# == Schema Information
#
# Table name: captain_follow_up_attempts
#
#  id                    :bigint           not null, primary key
#  attempt_key           :string(64)       not null
#  completed_at          :datetime
#  expires_at            :datetime         not null
#  generated_at          :datetime
#  generated_content     :text
#  processing_started_at :datetime         not null
#  status                :string           default("processing"), not null
#  step_index            :integer          not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :bigint           not null
#  anchor_message_id     :bigint           not null
#  assistant_id          :bigint           not null
#  conversation_id       :bigint           not null
#
# Indexes
#
#  index_captain_follow_up_attempts_on_account_id             (account_id)
#  index_captain_follow_up_attempts_on_anchor_and_created_at  (anchor_message_id,created_at)
#  index_captain_follow_up_attempts_on_anchor_message_id      (anchor_message_id)
#  index_captain_follow_up_attempts_on_assistant_id           (assistant_id)
#  index_captain_follow_up_attempts_on_attempt_key            (attempt_key) UNIQUE
#  index_captain_follow_up_attempts_on_conversation_id        (conversation_id)
#  index_captain_follow_up_attempts_on_status_and_expires_at  (status,expires_at)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (anchor_message_id => messages.id) ON DELETE => cascade
#  fk_rails_...  (assistant_id => captain_assistants.id) ON DELETE => cascade
#  fk_rails_...  (conversation_id => conversations.id) ON DELETE => cascade
#
class Captain::FollowUpAttempt < ApplicationRecord
  self.table_name = 'captain_follow_up_attempts'

  STATUSES = %w[processing generated completed failed expired].freeze

  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant'
  belongs_to :conversation, class_name: '::Conversation'
  belongs_to :anchor_message, class_name: '::Message'

  enum :status, STATUSES.index_with(&:itself), validate: true

  validates :attempt_key, presence: true, length: { maximum: 64 }
  validates :step_index, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :processing_started_at, :expires_at, presence: true
end
