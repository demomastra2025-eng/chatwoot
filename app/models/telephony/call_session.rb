# == Schema Information
#
# Table name: telephony_call_sessions
#
#  id                :bigint           not null, primary key
#  answered_at       :datetime
#  answered_by       :string
#  direction         :string           default("outbound"), not null
#  duration_seconds  :integer
#  end_reason        :string
#  ended_at          :datetime
#  ended_by          :string
#  external_call_ref :string           not null
#  from_number       :string
#  last_event_at     :datetime
#  legs              :jsonb            not null
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
#  fk_rails_...  (conversation_id => conversations.id) ON DELETE => nullify
#  fk_rails_...  (inbox_id => inboxes.id) ON DELETE => nullify
#  fk_rails_...  (number_binding_id => telephony_number_bindings.id)
#
class Telephony::CallSession < ApplicationRecord
  self.table_name = 'telephony_call_sessions'

  CANONICAL_STATUSES = %w[created ringing connecting in_progress completed missed no_answer busy cancelled rejected failed].freeze
  STATUS_ALIASES = {
    'queued' => 'created',
    'initiated' => 'created',
    'answered' => 'in_progress',
    'in-progress' => 'in_progress',
    'inprogress' => 'in_progress',
    'no-answer' => 'no_answer',
    'noanswer' => 'no_answer',
    'canceled' => 'cancelled',
    'declined' => 'rejected',
    'ended' => 'completed',
    'hangup' => 'completed',
    'session_started' => 'ringing',
    'decision_received' => 'ringing',
    'operator_ringing' => 'ringing',
    'operator_answered' => 'in_progress',
    'operator_no_answer' => 'no_answer',
    'operator_timeout' => 'no_answer',
    'operator_failed' => 'failed',
    'caller_hangup' => 'cancelled',
    'timeout' => 'no_answer',
    'session_completed' => 'completed',
    'session_failed' => 'failed',
    'media_stream_closed' => 'failed',
    'media_stream_not_established' => 'failed',
    'provider_error' => 'failed',
    'unsupported_action' => 'failed'
  }.freeze
  ALLOWED_STATUSES = (CANONICAL_STATUSES + STATUS_ALIASES.keys).uniq.freeze
  TERMINAL_STATUSES = %w[completed missed no_answer busy cancelled rejected failed].freeze
  TERMINAL_STATUS_VALUES = (TERMINAL_STATUSES + STATUS_ALIASES.select { |_key, value| TERMINAL_STATUSES.include?(value) }.keys).uniq.freeze
  ALLOWED_DIRECTIONS = %w[inbound outbound].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :conversation, class_name: '::Conversation', optional: true
  belongs_to :contact, class_name: '::Contact', optional: true
  belongs_to :inbox, class_name: '::Inbox', optional: true
  belongs_to :number_binding, class_name: '::Telephony::NumberBinding', optional: true
  belongs_to :agent_binding, class_name: '::Telephony::AgentBinding', optional: true

  has_many :events, class_name: '::Telephony::Event', dependent: :destroy

  before_validation :normalize_status_value

  validates :provider, presence: true
  validates :external_call_ref, presence: true, uniqueness: { scope: :account_id }
  validates :status, presence: true, inclusion: { in: ALLOWED_STATUSES }, allow_blank: false
  validates :direction, presence: true, inclusion: { in: ALLOWED_DIRECTIONS }, allow_blank: false

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :active, -> { where.not(status: TERMINAL_STATUS_VALUES) }

  def self.normalize_status(value)
    normalized = value.to_s.strip.downcase.tr(' ', '_')
    return if normalized.blank?

    STATUS_ALIASES[normalized] || (normalized if CANONICAL_STATUSES.include?(normalized))
  end

  def canonical_status
    self.class.normalize_status(status) || status
  end

  def terminal?
    TERMINAL_STATUSES.include?(canonical_status)
  end

  def latest_voice_message
    conversation&.messages&.voice_calls&.order(created_at: :desc)&.first
  end

  def voice_call_source_id
    "voice_call:#{external_call_ref}"
  end

  def exact_voice_message
    conversation&.messages&.voice_calls&.find_by(source_id: voice_call_source_id)
  end

  def voice_message_for_current_call
    linked_parent_voice_message || exact_voice_message || voice_message_with_call_ref || single_legacy_voice_message || legacy_current_call_message
  end

  def to_telephony_h
    {
      id: id,
      call_ref: external_call_ref,
      provider_call_sid: provider_call_sid,
      provider: provider,
      status: canonical_status,
      legacy_status: status == canonical_status ? nil : status,
      direction: direction,
      from_number: from_number,
      to_number: to_number,
      duration_seconds: duration_seconds,
      duration_sec: duration_seconds,
      started_at: started_at,
      answered_at: answered_at,
      answered_by: answered_by,
      ended_at: ended_at,
      ended_by: ended_by,
      end_reason: end_reason,
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
      legs: legs || [],
      metadata: metadata
    }.compact
  end

  private

  def single_legacy_voice_message
    voice_messages = conversation&.messages&.voice_calls&.order(created_at: :desc, id: :desc)
    return unless voice_messages&.limit(2)&.count == 1

    message = voice_messages.first
    return message if voice_message_data(message)['call_sid'].blank? && message.source_id.blank?
  end

  def linked_parent_voice_message
    parent_ref = linked_parent_call_ref
    return if parent_ref.blank? || parent_ref == external_call_ref

    conversation&.messages&.voice_calls&.find_by(source_id: "voice_call:#{parent_ref}") ||
      conversation&.messages&.voice_calls&.order(created_at: :desc, id: :desc)&.detect do |message|
        voice_message_data(message)['call_sid'] == parent_ref
      end
  end

  def linked_parent_call_ref
    ai_voice = metadata.to_h['ai_voice'].is_a?(Hash) ? metadata.to_h['ai_voice'] : {}
    linked_terminal = ai_voice['linked_parent_terminal'].is_a?(Hash) ? ai_voice['linked_parent_terminal'] : {}
    last_payload = metadata.to_h['last_payload'].is_a?(Hash) ? metadata.to_h['last_payload'] : {}
    nested_payload = last_payload['payload'].is_a?(Hash) ? last_payload['payload'] : {}

    linked_terminal['bridge_call_ref'].presence ||
      last_payload['bridge_call_ref'].presence || last_payload['bridgeCallRef'].presence ||
      nested_payload['bridge_call_ref'].presence || nested_payload['bridgeCallRef'].presence
  end

  def voice_message_with_call_ref
    conversation&.messages&.voice_calls&.order(created_at: :desc, id: :desc)&.detect do |message|
      voice_message_data(message)['call_sid'] == external_call_ref
    end
  end

  def legacy_current_call_message
    return unless conversation&.identifier == external_call_ref

    latest_voice_message
  end

  def voice_message_data(message)
    content_attributes = (message.content_attributes || {}).to_h
    data = content_attributes['data'] || content_attributes[:data]
    data.is_a?(Hash) ? data.deep_stringify_keys : {}
  end

  def normalize_status_value
    self.status = self.class.normalize_status(status) || status
  end
end
