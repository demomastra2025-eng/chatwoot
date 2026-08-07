# frozen_string_literal: true

# == Schema Information
#
# Table name: meta_channel_credential_healths
#
#  id                     :bigint           not null, primary key
#  channel_type           :string           not null
#  checked_at             :datetime
#  consecutive_failures   :integer          default(0), not null
#  data_access_expires_at :datetime
#  expires_at             :datetime
#  last_failed_at         :datetime
#  last_healthy_at        :datetime
#  metadata               :jsonb            not null
#  provider_code          :integer
#  provider_subcode       :integer
#  provider_type          :string
#  reason                 :string
#  status                 :string           default("unknown"), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#  channel_id             :bigint           not null
#  provider_trace_id      :string
#
# Indexes
#
#  index_meta_channel_credential_healths_on_account_id      (account_id)
#  index_meta_channel_credential_healths_on_account_status  (account_id,status)
#  index_meta_channel_credential_healths_on_channel         (channel_type,channel_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#
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
