# frozen_string_literal: true

# Pending review bank. No callbacks that embed text, publish FAQ, or change prompts.
class Captain::ShadowTraining::Candidate < ApplicationRecord
  self.table_name = 'captain_shadow_training_candidates'

  belongs_to :account, class_name: '::Account'
  belongs_to :run, class_name: 'Captain::ShadowTraining::Run'

  validates :kind, inclusion: { in: %w[faq regression] }
  validates :status, inclusion: { in: %w[pending rejected] }
  validates :proposal, presence: true
  validate :same_account

  private

  def same_account
    errors.add(:account, 'must own the shadow run') unless run&.account_id == account_id
  end
end
