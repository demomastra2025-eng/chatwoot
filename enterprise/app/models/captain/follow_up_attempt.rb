# frozen_string_literal: true

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
