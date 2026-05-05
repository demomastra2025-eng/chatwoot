# == Schema Information
#
# Table name: telephony_agent_bindings
#
#  id              :bigint           not null, primary key
#  agent_aor       :string
#  agent_ref       :string           not null
#  credentials_ref :string
#  domain_ref      :string
#  enabled         :boolean          default(TRUE), not null
#  last_synced_at  :datetime
#  metadata        :jsonb            not null
#  provider        :string           default("fonoster"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  user_id         :bigint           not null
#
# Indexes
#
#  index_telephony_agent_bindings_on_account_agent_ref  (account_id,agent_ref) UNIQUE
#  index_telephony_agent_bindings_on_account_id         (account_id)
#  index_telephony_agent_bindings_on_account_user       (account_id,user_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (user_id => users.id)
#
class Telephony::AgentBinding < ApplicationRecord
  self.table_name = 'telephony_agent_bindings'

  belongs_to :account, class_name: '::Account'
  belongs_to :user, class_name: '::User'

  has_many :call_sessions, class_name: '::Telephony::CallSession', dependent: :nullify, inverse_of: :agent_binding

  validates :provider, presence: true
  validates :agent_ref, presence: true, uniqueness: { scope: :account_id }
  validates :user_id, uniqueness: { scope: :account_id }

  scope :enabled, -> { where(enabled: true) }
  scope :recent, -> { order(updated_at: :desc, id: :desc) }

  def to_telephony_h
    {
      id: id,
      user_id: user_id,
      user_name: user&.name,
      provider: provider,
      agent_ref: agent_ref,
      agent_aor: agent_aor,
      domain_ref: domain_ref,
      credentials_ref: credentials_ref,
      enabled: enabled,
      registered_for_routing: registered_for_routing?,
      registration_state: metadata_value('registration_state', 'registrationState', 'registration', 'presence', 'status', 'state'),
      last_presence_source: metadata_value('last_presence_source'),
      last_presence_event_at: metadata_value('last_presence_event_at'),
      last_synced_at: last_synced_at
    }.compact
  end

  def update_browser_registration!(registered:, occurred_at: Time.current)
    registration_metadata = (metadata || {}).deep_dup
    registration_metadata['registration_state'] = registered ? 'registered' : 'offline'
    registration_metadata['presence'] = registered ? 'online' : 'offline'
    registration_metadata['registered'] = registered
    registration_metadata['available'] = registered
    registration_metadata['last_presence_source'] = 'browser_webphone'
    registration_metadata['last_presence_event_at'] = occurred_at.iso8601

    update!(metadata: registration_metadata, last_synced_at: occurred_at)
  end

  def registered_for_routing?
    return false unless enabled?

    registration_state = metadata_value('registration_state', 'registrationState', 'registration', 'presence', 'status', 'state')
    return truthy_metadata?('registered', 'online', 'available') if registration_state.blank?

    %w[registered online available reachable active].include?(registration_state.to_s.strip.downcase)
  end

  private

  def metadata_value(*keys)
    source = metadata || {}
    keys.lazy.map { |key| source[key.to_s] || source[key.to_sym] }.find(&:present?)
  end

  def truthy_metadata?(*keys)
    keys.any? { |key| ActiveModel::Type::Boolean.new.cast(metadata_value(key)) }
  end
end
