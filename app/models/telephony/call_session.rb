# == Schema Information
#
# Table name: telephony_call_sessions
#
#  id                :bigint           not null, primary key
#  direction         :string           default("outbound"), not null
#  duration_seconds  :integer
#  ended_at          :datetime
#  external_call_ref :string           not null
#  from_number       :string
#  last_event_at     :datetime
#  metadata          :jsonb            not null
#  provider          :string           default("fonoster"), not null
#  provider_call_sid :string
#  recording_ref     :string
#  started_at        :datetime
#  status            :string           default("ringing"), not null
#  summary           :text
#  to_number         :string
#  transcript_ref    :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#  agent_binding_id  :bigint
#  contact_id        :bigint
#  conversation_id   :bigint
#  inbox_id          :bigint
#  number_binding_id :bigint
#
# Indexes
#
#  index_telephony_call_sessions_on_account_call_ref          (account_id,external_call_ref) UNIQUE
#  index_telephony_call_sessions_on_account_conversation      (account_id,conversation_id)
#  index_telephony_call_sessions_on_account_created_at        (account_id,created_at)
#  index_telephony_call_sessions_on_account_id                (account_id)
#  index_telephony_call_sessions_on_account_provider_sid      (account_id,provider_call_sid) UNIQUE WHERE (provider_call_sid IS NOT NULL)
#  index_telephony_call_sessions_on_account_status_direction  (account_id,status,direction)
#  index_telephony_call_sessions_on_agent_binding_id          (agent_binding_id)
#  index_telephony_call_sessions_on_contact_id                (contact_id)
#  index_telephony_call_sessions_on_conversation_id           (conversation_id)
#  index_telephony_call_sessions_on_inbox_id                  (inbox_id)
#  index_telephony_call_sessions_on_number_binding_id         (number_binding_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (agent_binding_id => telephony_agent_bindings.id)
#  fk_rails_...  (contact_id => contacts.id)
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#  fk_rails_...  (number_binding_id => telephony_number_bindings.id)
#
class Telephony::CallSession < ApplicationRecord
  self.table_name = 'telephony_call_sessions'

  ALLOWED_STATUSES = %w[ringing in-progress completed no-answer failed queued].freeze
  TERMINAL_STATUSES = %w[completed no-answer failed].freeze
  ALLOWED_DIRECTIONS = %w[inbound outbound].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :conversation, class_name: '::Conversation', optional: true
  belongs_to :contact, class_name: '::Contact', optional: true
  belongs_to :inbox, class_name: '::Inbox', optional: true
  belongs_to :number_binding, class_name: '::Telephony::NumberBinding', optional: true
  belongs_to :agent_binding, class_name: '::Telephony::AgentBinding', optional: true

  has_many :events, class_name: '::Telephony::Event', foreign_key: :call_session_id, dependent: :destroy

  validates :provider, presence: true
  validates :external_call_ref, presence: true, uniqueness: { scope: :account_id }
  validates :status, presence: true, inclusion: { in: ALLOWED_STATUSES }, allow_blank: false
  validates :direction, presence: true, inclusion: { in: ALLOWED_DIRECTIONS }, allow_blank: false

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :active, -> { where.not(status: TERMINAL_STATUSES) }

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def latest_voice_message
    conversation&.messages&.voice_calls&.order(created_at: :desc)&.first
  end

  def to_telephony_h
    {
      id: id,
      call_ref: external_call_ref,
      provider_call_sid: provider_call_sid,
      provider: provider,
      status: status,
      direction: direction,
      from_number: from_number,
      to_number: to_number,
      duration_seconds: duration_seconds,
      started_at: started_at,
      ended_at: ended_at,
      recording_ref: recording_ref,
      transcript_ref: transcript_ref,
      summary: summary,
      conversation_id: conversation&.display_id,
      conversation_db_id: conversation_id,
      contact_id: contact_id,
      contact_name: contact&.name,
      inbox_id: inbox_id,
      inbox_name: inbox&.name,
      number_ref: number_binding&.number_ref,
      agent_ref: agent_binding&.agent_ref,
      last_event_at: last_event_at,
      metadata: metadata
    }.compact
  end
end
