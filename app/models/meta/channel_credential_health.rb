# frozen_string_literal: true

class Meta::ChannelCredentialHealth < ApplicationRecord
  self.table_name = 'meta_channel_credential_healths'

  STATUSES = %w[unknown healthy expiring degraded transient_failure action_required].freeze

  belongs_to :account
  belongs_to :channel, polymorphic: true

  validates :status, inclusion: { in: STATUSES }
  validates :channel_id, uniqueness: { scope: :channel_type }
  validate :account_matches_channel

  private

  def account_matches_channel
    return if account_id.blank? || channel.blank? || !channel.respond_to?(:account_id)
    return if account_id == channel.account_id

    errors.add(:account, 'must match channel account')
  end
end
