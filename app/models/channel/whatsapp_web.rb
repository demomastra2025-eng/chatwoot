# == Schema Information
#
# Table name: channel_whatsapp_web
#
#  id                    :bigint           not null, primary key
#  connection_state      :string           default("close"), not null
#  conversation_pending  :boolean          default(FALSE), not null
#  history_lookback_days :integer          default(365), not null
#  ignore_jids           :jsonb            not null
#  import_contacts       :boolean          default(TRUE), not null
#  import_messages       :boolean          default(TRUE), not null
#  instance_name         :string           not null
#  last_error            :text
#  last_synced_at        :datetime
#  lifecycle_state       :string           default("creating"), not null
#  phone_number          :string           not null
#  provider              :string           default("evolution"), not null
#  provider_config       :jsonb            not null
#  qr_code               :jsonb            not null
#  sign_delimiter        :string           default("\\n"), not null
#  sign_messages         :boolean          default(FALSE), not null
#  sync_labels           :boolean          default(TRUE), not null
#  sync_state            :jsonb            not null
#  webhook_identifier    :string           not null
#  webhook_secret        :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :integer          not null
#
# Indexes
#
#  index_channel_whatsapp_web_on_instance_name       (instance_name) UNIQUE
#  index_channel_whatsapp_web_on_webhook_identifier  (webhook_identifier) UNIQUE
#

class Channel::WhatsappWeb < ApplicationRecord
  include Channelable

  PROVIDERS = %w[evolution].freeze
  DEFAULT_IGNORE_REMOTE_JIDS = %w[status@broadcast].freeze
  LIFECYCLE_STATES = %w[creating waiting_for_qr qr_ready connected disconnected failed].freeze
  CONNECTION_STATES = %w[open connecting close refused unknown].freeze
  DEFAULT_SYNC_STATE = {
    'history_synced_at' => nil,
    'history_sync_requested_at' => nil,
    'last_fulfilled_history_sync_requested_at' => nil,
    'last_local_history_sync_finished_at' => nil,
    'last_history_sync_mode' => nil,
    'last_history_sync_error' => nil,
    'last_history_message_count' => 0,
    'last_history_contact_count' => 0,
    'last_incremental_sync_at' => nil,
    'provider_history_synced_at' => nil,
    'local_history_provider_synced_at' => nil,
    'provider_history_message_count' => 0,
    'provider_history_contact_count' => 0,
    'history_sync_expected_provider_synced_at' => nil,
    'echo_status_miss_count' => 0,
    'last_echo_status_miss_at' => nil,
    'last_echo_status_miss_source_id' => nil,
    'qr_generated_at' => nil,
    'label_map' => {}
  }.freeze
  HISTORY_SYNC_REQUEST_STALE_AFTER = 30.minutes
  IMMUTABLE_RUNTIME_ATTRS = %i[phone_number provider provider_config].freeze
  EDITABLE_ATTRS = [
    :phone_number, :provider, :conversation_pending, :history_lookback_days,
    :sign_messages, :sign_delimiter, :import_contacts, :import_messages, :sync_labels,
    { provider_config: {} }, { ignore_jids: [] }
  ].freeze

  self.table_name = 'channel_whatsapp_web'

  has_secure_token :webhook_identifier
  has_secure_token :webhook_secret

  before_validation :normalize_phone_number!
  before_validation :normalize_ignore_jids!
  before_validation :ensure_defaults!

  validates :provider, inclusion: { in: PROVIDERS }
  validates :lifecycle_state, inclusion: { in: LIFECYCLE_STATES }
  validates :connection_state, inclusion: { in: CONNECTION_STATES }
  validates :phone_number, presence: true, format: { with: /\A\+\d{6,15}\z/, message: 'must be in E.164 format' }
  validates :history_lookback_days, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 3650 }
  validates :sign_delimiter, length: { maximum: 20 }
  validates :instance_name, presence: true, uniqueness: true
  validates :webhook_identifier, presence: true, uniqueness: true
  validates :webhook_secret, presence: true
  validate :ensure_runtime_configuration
  validate :ensure_ignore_jids_array
  validate :runtime_identity_is_immutable, on: :update

  after_create_commit :enqueue_provisioning
  before_destroy :teardown_provider_instance

  def name
    'WhatsApp Web'
  end

  def provider_service
    case provider
    when 'evolution'
      WhatsappWeb::Providers::EvolutionService.new(channel: self)
    else
      raise ArgumentError, "Unsupported WhatsApp Web provider: #{provider}"
    end
  end

  delegate :provision!, :refresh_qr!, :reconnect!, :disconnect!, :repair!, :sync_connection_state!, :diagnostics,
           :send_message, to: :provider_service

  def generated_inbox_name
    phone_number.delete_prefix('+')
  end

  def generated_instance_name_suffix
    [account_id, generated_inbox_name].compact.join('_')
  end

  def pairing_number
    phone_number.delete_prefix('+')
  end

  def webhook_callback_url
    "#{frontend_url}/webhooks/whatsapp_web/#{webhook_identifier}"
  end

  def history_lookback_window
    history_lookback_days.days
  end

  def custom_ignore_jids
    Array.wrap(ignore_jids).filter_map { |jid| jid.to_s.strip.presence }.uniq
  end

  def effective_ignore_jids
    (DEFAULT_IGNORE_REMOTE_JIDS + custom_ignore_jids).uniq
  end

  def ignored_remote_jid?(remote_jid)
    effective_ignore_jids.include?(remote_jid.to_s)
  end

  def formatted_sign_delimiter
    sign_delimiter.to_s.gsub('\\n', "\n").presence || "\n"
  end

  def history_sync_enabled?
    import_contacts? || import_messages?
  end

  def sync_state_payload
    DEFAULT_SYNC_STATE.deep_merge((sync_state || {}).deep_stringify_keys)
  end

  def history_synced_at
    value = sync_state_payload['history_synced_at']
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def history_sync_requested_at
    value = sync_state_payload['history_sync_requested_at']
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def last_incremental_sync_at
    value = sync_state_payload['last_incremental_sync_at']
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def last_local_history_sync_finished_at
    value = sync_state_payload['last_local_history_sync_finished_at']
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def last_fulfilled_history_sync_requested_at
    value = sync_state_payload['last_fulfilled_history_sync_requested_at']
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def provider_history_synced_at
    value = sync_state_payload['provider_history_synced_at']
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def local_history_provider_synced_at
    value = sync_state_payload['local_history_provider_synced_at']
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def history_sync_expected_provider_synced_at
    value = sync_state_payload['history_sync_expected_provider_synced_at']
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def qr_generated_at
    value = sync_state_payload['qr_generated_at']
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def label_map
    sync_state_payload['label_map'].is_a?(Hash) ? sync_state_payload['label_map'] : {}
  end

  def last_history_sync_mode
    sync_state_payload['last_history_sync_mode'].presence
  end

  def history_sync_in_progress?
    return false unless history_sync_enabled?

    requested_at = history_sync_requested_at
    return false if requested_at.blank?

    !history_sync_request_fulfilled?(
      requested_at: requested_at,
      expected_provider_history_synced_at: history_sync_expected_provider_synced_at
    )
  end

  def full_history_baseline_present?
    return false if history_synced_at.blank?
    return false if import_messages? && sync_state_payload['last_history_message_count'].to_i <= 0 && inbox.messages.none?
    return false if import_contacts? && sync_state_payload['last_history_contact_count'].to_i <= 0 && inbox.contact_inboxes.none?

    true
  end

  def full_history_baseline_current?
    return false unless full_history_baseline_present?
    return true if provider_history_synced_at.blank?

    if local_history_provider_synced_at.present?
      return local_history_provider_synced_at >= provider_history_synced_at - 1.second
    end

    history_synced_at >= provider_history_synced_at
  end

  def preferred_history_sync_mode
    full_history_baseline_present? ? 'incremental' : 'full'
  end

  def history_sync_request_pending?(stale_after: HISTORY_SYNC_REQUEST_STALE_AFTER)
    requested_at = history_sync_requested_at
    return false if requested_at.blank?
    return false if history_sync_request_fulfilled?(
      requested_at: requested_at,
      expected_provider_history_synced_at: history_sync_expected_provider_synced_at
    )
    return false if stale_after.present? && requested_at < stale_after.ago

    true
  end

  def history_sync_request_fulfilled?(requested_at: nil, expected_provider_history_synced_at: nil)
    expected_snapshot = normalize_sync_snapshot_time(expected_provider_history_synced_at)
    if expected_snapshot.present?
      return false if local_history_provider_synced_at.blank?

      return local_history_provider_synced_at >= expected_snapshot - 1.second
    end

    requested_time = normalize_sync_snapshot_time(requested_at)
    return false if requested_time.blank? || last_fulfilled_history_sync_requested_at.blank?

    last_fulfilled_history_sync_requested_at >= requested_time - 1.second
  end

  def request_history_sync!(mode, force: false, wait: nil, expected_provider_history_synced_at: nil)
    normalized_mode = mode.to_s == 'full' ? 'full' : 'incremental'
    return false unless history_sync_enabled?

    with_lock do
      reload
      expected_snapshot = normalize_sync_snapshot_time(expected_provider_history_synced_at)
      if !force && history_sync_request_pending? &&
         !provider_snapshot_supersedes_pending_request?(expected_snapshot)
        return false
      end

      request_time = Time.current
      update!(
        sync_state: sync_state_payload.merge(
          'history_sync_requested_at' => request_time.iso8601,
          'last_history_sync_mode' => normalized_mode,
          'last_history_sync_error' => nil,
          'history_sync_expected_provider_synced_at' => expected_snapshot&.iso8601
        )
      )

      sync_context = { 'requested_at' => request_time.iso8601 }
      if expected_snapshot.present?
        sync_context['expected_provider_history_synced_at'] = expected_snapshot.iso8601
      end

      job = Channels::WhatsappWeb::HistorySyncJob
      job = job.set(wait: wait) if wait.present?
      job.perform_later(id, normalized_mode, sync_context)
      true
    end
  end

  def record_history_sync!(message_count:, contact_count:, incremental: false, error: nil,
                           fulfilled_provider_history_synced_at: nil, sync_context: {})
    record_sync_result!(
      mode: incremental ? 'incremental' : 'full',
      message_count: message_count,
      contact_count: contact_count,
      error: error,
      fulfilled_provider_history_synced_at: fulfilled_provider_history_synced_at,
      sync_context: sync_context
    )
  end

  def record_incremental_sync!(message_count:, error: nil, fulfilled_provider_history_synced_at: nil, sync_context: {})
    record_sync_result!(
      mode: 'incremental',
      message_count: message_count,
      contact_count: nil,
      error: error,
      fulfilled_provider_history_synced_at: fulfilled_provider_history_synced_at,
      sync_context: sync_context
    )
  end

  def record_provider_history_snapshot!(message_count:, contact_count:)
    timestamp = Time.current

    with_lock do
      reload
      payload = sync_state_payload.merge(
        'provider_history_synced_at' => timestamp.iso8601,
        'provider_history_message_count' => message_count,
        'provider_history_contact_count' => contact_count
      )

      update!(sync_state: payload, last_synced_at: timestamp)
    end
  end

  def record_echo_status_miss!(source_id:)
    timestamp = Time.current

    with_lock do
      reload
      payload = sync_state_payload.merge(
        'echo_status_miss_count' => sync_state_payload['echo_status_miss_count'].to_i + 1,
        'last_echo_status_miss_at' => timestamp.iso8601,
        'last_echo_status_miss_source_id' => source_id
      )

      update!(sync_state: payload, last_synced_at: timestamp)
    end
  end

  def update_label_map!(next_label_map)
    with_lock do
      reload
      payload = sync_state_payload.merge('label_map' => next_label_map.deep_stringify_keys)
      update!(sync_state: payload)
    end
  end

  def evolution_state_payload
    payload = {
      'status' => lifecycle_state,
      'connection_state' => connection_state,
      'instance_name' => instance_name,
      'number' => phone_number,
      'last_synced_at' => last_synced_at&.iso8601,
      'last_error' => last_error,
      'history_synced_at' => sync_state_payload['history_synced_at'],
      'history_sync_requested_at' => sync_state_payload['history_sync_requested_at'],
      'last_fulfilled_history_sync_requested_at' => sync_state_payload['last_fulfilled_history_sync_requested_at'],
      'last_local_history_sync_finished_at' => sync_state_payload['last_local_history_sync_finished_at'],
      'history_sync_in_progress' => history_sync_in_progress?,
      'last_history_sync_mode' => sync_state_payload['last_history_sync_mode'],
      'last_incremental_sync_at' => sync_state_payload['last_incremental_sync_at'],
      'last_history_sync_error' => sync_state_payload['last_history_sync_error'],
      'last_history_message_count' => sync_state_payload['last_history_message_count'],
      'last_history_contact_count' => sync_state_payload['last_history_contact_count'],
      'provider_history_synced_at' => sync_state_payload['provider_history_synced_at'],
      'local_history_provider_synced_at' => sync_state_payload['local_history_provider_synced_at'],
      'provider_history_message_count' => sync_state_payload['provider_history_message_count'],
      'provider_history_contact_count' => sync_state_payload['provider_history_contact_count'],
      'history_sync_expected_provider_synced_at' => sync_state_payload['history_sync_expected_provider_synced_at'],
      'echo_status_miss_count' => sync_state_payload['echo_status_miss_count'],
      'last_echo_status_miss_at' => sync_state_payload['last_echo_status_miss_at'],
      'last_echo_status_miss_source_id' => sync_state_payload['last_echo_status_miss_source_id'],
      'qr_generated_at' => sync_state_payload['qr_generated_at']
    }

    payload['qrcode'] = qr_code if qr_code.present?
    payload['service_user'] = provider_config['service_user'] if provider_config['service_user'].present?
    payload.compact
  end

  def mark_failed!(message)
    update!(
      lifecycle_state: 'failed',
      last_error: message,
      last_synced_at: Time.current
    )
  end

  private

  def record_sync_result!(mode:, message_count:, contact_count:, error:, fulfilled_provider_history_synced_at:, sync_context:)
    timestamp = Time.current
    sync_context = sync_context.to_h.with_indifferent_access
    completed_requested_at = normalize_sync_snapshot_time(sync_context[:requested_at])
    completed_snapshot = normalize_sync_snapshot_time(
      fulfilled_provider_history_synced_at || sync_context[:expected_provider_history_synced_at]
    )

    with_lock do
      reload

      payload = sync_state_payload
      current_requested_at = normalize_sync_snapshot_time(payload['history_sync_requested_at'])
      current_expected_snapshot = normalize_sync_snapshot_time(payload['history_sync_expected_provider_synced_at'])
      current_local_snapshot = normalize_sync_snapshot_time(payload['local_history_provider_synced_at'])
      completed_snapshot ||= current_expected_snapshot || provider_history_synced_at
      fulfilled_requested_at = completed_requested_at || current_requested_at

      keep_pending_request = pending_history_sync_request_after_completion?(
        current_requested_at: current_requested_at,
        current_expected_snapshot: current_expected_snapshot,
        completed_requested_at: fulfilled_requested_at,
        completed_snapshot: completed_snapshot
      )

      next_local_snapshot = if error.present?
                              current_local_snapshot
                            else
                              [current_local_snapshot, completed_snapshot].compact.max
                            end

      next_payload = payload.merge(
        'history_sync_requested_at' => (current_requested_at || completed_requested_at || timestamp).iso8601,
        'last_fulfilled_history_sync_requested_at' => if error.present?
                                                        payload['last_fulfilled_history_sync_requested_at']
                                                      else
                                                        [
                                                          normalize_sync_snapshot_time(payload['last_fulfilled_history_sync_requested_at']),
                                                          fulfilled_requested_at
                                                        ].compact.max&.iso8601
                                                      end,
        'last_local_history_sync_finished_at' => timestamp.iso8601,
        'last_history_sync_mode' => mode,
        'history_synced_at' => mode == 'full' && error.blank? ? timestamp.iso8601 : payload['history_synced_at'],
        'last_incremental_sync_at' => mode == 'incremental' && error.blank? ? timestamp.iso8601 : payload['last_incremental_sync_at'],
        'last_history_message_count' => message_count,
        'last_history_sync_error' => error,
        'history_sync_expected_provider_synced_at' => keep_pending_request ? payload['history_sync_expected_provider_synced_at'] : nil,
        'local_history_provider_synced_at' => next_local_snapshot&.iso8601
      )
      next_payload['last_history_contact_count'] = contact_count unless contact_count.nil?

      update!(sync_state: next_payload, last_synced_at: timestamp, last_error: error)
    end
  end

  def pending_history_sync_request_after_completion?(current_requested_at:, current_expected_snapshot:,
                                                     completed_requested_at:, completed_snapshot:)
    if current_expected_snapshot.present?
      return true if completed_snapshot.blank?

      return current_expected_snapshot > completed_snapshot + 1.second
    end

    return false if current_requested_at.blank? || completed_requested_at.blank?

    current_requested_at > completed_requested_at + 1.second
  end

  def provider_snapshot_supersedes_pending_request?(expected_snapshot)
    return true unless history_sync_request_pending?
    return false if expected_snapshot.blank?

    pending_expected_snapshot = history_sync_expected_provider_synced_at
    return true if pending_expected_snapshot.blank?

    expected_snapshot > pending_expected_snapshot + 1.second
  end

  def normalize_sync_snapshot_time(value)
    return if value.blank?
    return value.in_time_zone if value.respond_to?(:in_time_zone)

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def normalize_phone_number!
    return if phone_number.blank?

    digits = phone_number.to_s.gsub(/\D/, '')
    self.phone_number = digits.present? ? "+#{digits}" : nil
  end

  def normalize_ignore_jids!
    normalized = Array.wrap(ignore_jids).flat_map do |value|
      value.is_a?(String) ? value.split(/[\r\n,]+/) : value
    end.filter_map do |value|
      value.to_s.strip.presence
    end.uniq

    self.ignore_jids = normalized
  end

  def ensure_defaults!
    self.provider = 'evolution' if provider.blank?
    self.provider_config = (provider_config || {}).deep_stringify_keys
    self.qr_code = (qr_code || {}).deep_stringify_keys
    self.sync_state = DEFAULT_SYNC_STATE.deep_merge((sync_state || {}).deep_stringify_keys)
    self.ignore_jids = [] if ignore_jids.blank?
    self.lifecycle_state = 'creating' if lifecycle_state.blank?
    self.connection_state = 'close' if connection_state.blank?
    self.conversation_pending = false if conversation_pending.nil?
    self.history_lookback_days = 365 if history_lookback_days.blank?
    self.sign_messages = false if sign_messages.nil?
    self.sign_delimiter = '\\n' if sign_delimiter.blank?
    self.import_contacts = true if import_contacts.nil?
    self.import_messages = true if import_messages.nil?
    self.sync_labels = true if sync_labels.nil?
    self.webhook_identifier ||= self.class.generate_unique_secure_token
    self.webhook_secret ||= self.class.generate_unique_secure_token
    self.instance_name ||= "onelink-waweb-#{generated_instance_name_suffix}"
  end

  def ensure_ignore_jids_array
    errors.add(:ignore_jids, 'must be an array') unless ignore_jids.is_a?(Array)
  end

  def ensure_runtime_configuration
    errors.add(:base, 'EVOLUTION_API_URL must be configured') if evolution_api_url.blank?
    errors.add(:base, 'EVOLUTION_API_KEY must be configured') if evolution_api_key.blank?
    errors.add(:base, 'FRONTEND_URL must be configured') if frontend_url.blank?
  end

  def runtime_identity_is_immutable
    IMMUTABLE_RUNTIME_ATTRS.each do |attribute|
      errors.add(attribute, 'cannot be changed after the inbox is created') if will_save_change_to_attribute?(attribute)
    end
  end

  def enqueue_provisioning
    Channels::WhatsappWeb::ProvisionJob.perform_later(id)
  end

  def teardown_provider_instance
    provider_service.destroy_remote_instance!
  rescue StandardError => e
    Rails.logger.warn("[WHATSAPP WEB] Failed to tear down instance #{instance_name}: #{e.message}")
    true
  end

  def evolution_api_url
    ENV.fetch('EVOLUTION_API_URL', '').to_s.chomp('/')
  end

  def evolution_api_key
    ENV.fetch('EVOLUTION_API_KEY', '').to_s
  end

  def frontend_url
    ENV.fetch('FRONTEND_URL', '').to_s.chomp('/')
  end
end
