module TelegramPersonalRuntimeState
  extend ActiveSupport::Concern

  # The gateway's snapshot carries the hash of a pending login code, which only the gateway uses: it is never stored, so it is
  # never shown in the inbox API nor sent back to the gateway
  SECRET_RUNTIME_KEYS = %w[pending_phone_code_hash].freeze
  DEFAULT_HISTORY_SYNC_CHECKPOINT = {
    'version' => 1, 'mode' => nil, 'requested_at' => nil, 'scan_started_at' => nil,
    'cutoff_at' => nil, 'total_dialog_count' => 0, 'dialog_user_ids' => [],
    'failed_dialog_ids' => [], 'last_dialog_error' => nil,
    'next_dialog_index' => 0, 'last_completed_dialog_id' => nil,
    'last_checkpoint_at' => nil, 'dialog_cursors' => {}
  }.freeze
  DEFAULT_RUNTIME_STATE = {
    'qr_login_url' => nil, 'qr_login_expires_at' => nil, 'qr_login_state' => nil,
    'qr_login_requested_at' => nil, 'qr_login_completed_at' => nil,
    'qr_login_expired_at' => nil, 'qr_login_failed_at' => nil,
    'history_sync_state' => nil, 'history_sync_reason' => nil, 'history_sync_mode' => nil,
    'history_sync_requested_at' => nil, 'history_sync_started_at' => nil,
    'history_sync_completed_at' => nil, 'full_history_sync_completed_at' => nil,
    'last_deep_reconcile_at' => nil, 'history_sync_failed_at' => nil,
    'history_sync_cancelled_at' => nil, 'history_sync_error' => nil,
    'history_sync_count' => 0, 'history_dialog_count' => 0,
    'history_sync_cutoff_at' => nil, 'history_synced_until' => nil,
    'history_sync_checkpoint' => DEFAULT_HISTORY_SYNC_CHECKPOINT,
    'contacts_sync_state' => nil, 'contacts_sync_reason' => nil,
    'contacts_sync_requested_at' => nil, 'contacts_sync_started_at' => nil,
    'contacts_sync_completed_at' => nil, 'contacts_sync_failed_at' => nil,
    'contacts_sync_cancelled_at' => nil, 'contacts_sync_error' => nil,
    'contacts_sync_count' => 0, 'contacts_synced_until' => nil,
    'ignored_chat_ids' => [], 'sync_groups' => false, 'calling_enabled' => true
  }.freeze

  def runtime_state_payload
    normalize_runtime_state(runtime_state)
  end

  def normalize_runtime_state_payload(value)
    normalize_runtime_state(value)
  end

  def sync_groups?
    ActiveModel::Type::Boolean.new.cast(runtime_state_payload['sync_groups']) == true
  end

  def calling_enabled?
    ActiveModel::Type::Boolean.new.cast(runtime_state_payload['calling_enabled']) != false
  end
  alias voice_enabled? calling_enabled?

  def calling_enabled=(value)
    casted = value.nil? || ActiveModel::Type::Boolean.new.cast(value) == true
    self.runtime_state = (runtime_state || {}).deep_stringify_keys.merge('calling_enabled' => casted)
  end
  alias voice_enabled= calling_enabled=

  def history_sync_checkpoint
    runtime_state_payload['history_sync_checkpoint']
  end

  private

  def normalize_runtime_state(value)
    payload = (value || {}).deep_stringify_keys.except(*SECRET_RUNTIME_KEYS)

    DEFAULT_RUNTIME_STATE.deep_merge(payload).tap do |runtime|
      normalize_history_checkpoint!(runtime)
      normalize_sync_counters!(runtime)
      normalize_runtime_flags!(runtime)
    end
  end

  def normalize_history_checkpoint!(runtime)
    raw = runtime['history_sync_checkpoint']
    checkpoint = DEFAULT_HISTORY_SYNC_CHECKPOINT.deep_merge(raw.is_a?(Hash) ? raw.deep_stringify_keys : {})
    %w[dialog_user_ids failed_dialog_ids].each do |key|
      checkpoint[key] = Array.wrap(checkpoint[key]).filter_map { |item| item.to_s.presence }
    end
    %w[next_dialog_index total_dialog_count].each { |key| checkpoint[key] = checkpoint[key].to_i }
    checkpoint['dialog_cursors'] = checkpoint['dialog_cursors'].is_a?(Hash) ? checkpoint['dialog_cursors'].deep_stringify_keys : {}
    runtime['history_sync_checkpoint'] = checkpoint
  end

  def normalize_sync_counters!(runtime)
    runtime['history_sync_count'] = runtime['history_sync_count'].to_i
    runtime['history_dialog_count'] = runtime['history_dialog_count'].to_i
    runtime['contacts_sync_count'] = runtime['contacts_sync_count'].to_i
  end

  def normalize_runtime_flags!(runtime)
    ignored = normalize_ignored_chat_ids(runtime['ignored_chat_ids'])
    sync_groups = ActiveModel::Type::Boolean.new.cast(runtime['sync_groups']) == true
    raw_calling = runtime['calling_enabled']
    calling_enabled = raw_calling.nil? || ActiveModel::Type::Boolean.new.cast(raw_calling) == true

    runtime.compact_blank!
    runtime['ignored_chat_ids'] = ignored
    runtime['sync_groups'] = sync_groups
    runtime['calling_enabled'] = calling_enabled
  end

  def normalize_ignored_chat_ids(raw_ids)
    Array.wrap(raw_ids)
         .flat_map { |item| item.to_s.split(/[,\s;]+/) }
         .filter_map(&:presence)
         .uniq
  end
end
