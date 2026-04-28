# == Schema Information
#
# Table name: telephony_events
#
#  id              :bigint           not null, primary key
#  error_message   :text
#  event_key       :string           not null
#  event_type      :string           not null
#  payload         :jsonb            not null
#  processed_at    :datetime
#  status          :string           default("received"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  call_session_id :bigint
#
# Indexes
#
#  index_telephony_events_on_account_event_key              (account_id,event_key) UNIQUE
#  index_telephony_events_on_account_event_type_created_at  (account_id,event_type,created_at)
#  index_telephony_events_on_account_id                     (account_id)
#  index_telephony_events_on_call_session_id                (call_session_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (call_session_id => telephony_call_sessions.id)
#
class Telephony::Event < ApplicationRecord
  self.table_name = 'telephony_events'

  EVENT_STATUSES = %w[received processed failed].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :call_session, class_name: '::Telephony::CallSession', optional: true

  validates :event_key, presence: true, uniqueness: { scope: :account_id }
  validates :event_type, presence: true
  validates :status, presence: true, inclusion: { in: EVENT_STATUSES }

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def processed?
    status == 'processed'
  end

  def failed?
    status == 'failed'
  end
end
