# frozen_string_literal: true

# == Schema Information
#
# Table name: telephony_provisioning_runs
#
#  id                     :bigint           not null, primary key
#  desired_snapshot       :jsonb            not null
#  error_code             :string
#  error_details          :jsonb            not null
#  error_message          :text
#  executed_operations    :jsonb            not null
#  finished_at            :datetime
#  idempotency_key        :string           not null
#  operation              :string           not null
#  planned_operations     :jsonb            not null
#  remote_commit          :boolean          default(FALSE), not null
#  remote_snapshot        :jsonb            not null
#  started_at             :datetime
#  status                 :string           default("pending"), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#  channel_id             :bigint
#  inbox_id               :bigint
#  number_binding_id      :bigint
#  provider_connection_id :bigint
#  request_id             :string
#  requested_by_id        :bigint
#
# Indexes
#
#  idx_tel_provisioning_runs_account_idempotency                (account_id,idempotency_key) UNIQUE
#  idx_tel_provisioning_runs_account_inbox_created              (account_id,inbox_id,created_at)
#  idx_tel_provisioning_runs_account_status_created             (account_id,status,created_at)
#  index_telephony_provisioning_runs_on_account_id              (account_id)
#  index_telephony_provisioning_runs_on_inbox_id                (inbox_id)
#  index_telephony_provisioning_runs_on_number_binding_id       (number_binding_id)
#  index_telephony_provisioning_runs_on_provider_connection_id  (provider_connection_id)
#  index_telephony_provisioning_runs_on_requested_by_id         (requested_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#  fk_rails_...  (number_binding_id => telephony_number_bindings.id)
#  fk_rails_...  (provider_connection_id => telephony_provider_connections.id)
#  fk_rails_...  (requested_by_id => users.id)
#
require 'digest'
require 'securerandom'

class Telephony::ProvisioningRun < ApplicationRecord
  self.table_name = 'telephony_provisioning_runs'

  OPERATIONS = %w[create update delete reconcile dry_run provision readiness_check].freeze
  STATUSES = %w[pending running succeeded failed blocked cancelled].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :inbox, class_name: '::Inbox', optional: true
  belongs_to :channel, class_name: '::Channel::Voice', optional: true
  belongs_to :number_binding, class_name: '::Telephony::NumberBinding', optional: true
  belongs_to :provider_connection, class_name: '::Telephony::ProviderConnection', optional: true
  belongs_to :requested_by, class_name: '::User', optional: true

  validates :operation, presence: true, inclusion: { in: OPERATIONS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :idempotency_key, presence: true, uniqueness: { scope: :account_id }

  before_validation :normalize_values
  before_validation :sanitize_payloads

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def self.build_for(account:, operation:, desired_state:, plan:, current_user:, remote_commit:, status: 'pending')
    state = (desired_state || {}).with_indifferent_access
    resources = (state[:resources] || {}).with_indifferent_access

    new(
      account: account,
      inbox_id: state[:inbox_id],
      channel_id: state[:channel_id],
      number_binding_id: resources[:number_binding_id],
      provider_connection_id: resources[:provider_connection_id],
      operation: operation,
      status: status,
      remote_commit: remote_commit,
      idempotency_key: idempotency_key_for(operation: operation, desired_state: state),
      desired_snapshot: desired_state || {},
      planned_operations: Array.wrap(plan&.dig(:operations)),
      requested_by: current_user,
      request_id: Current.request_id
    )
  end

  def self.idempotency_key_for(operation:, desired_state:)
    state = desired_state.with_indifferent_access
    seed = [operation, state[:account_id], state[:inbox_id], state.dig(:refs, :number_ref), SecureRandom.uuid].join(':')
    "vpbx-run-#{Digest::SHA256.hexdigest(seed)[0, 32]}"
  end

  def self.remote_idempotency_key_for(operation:, desired_state:)
    state = desired_state.with_indifferent_access
    seed = canonical_json(
      operation: operation,
      account_id: state[:account_id],
      inbox_id: state[:inbox_id],
      number_ref: state.dig(:refs, :number_ref),
      desired_state: state
    )
    "vpbx-remote-#{Digest::SHA256.hexdigest(seed)[0, 32]}"
  end

  def self.canonical_json(value)
    JSON.generate(canonicalize(value))
  end

  def self.canonicalize(value)
    case value
    when Hash
      value.to_h.deep_stringify_keys.sort.each_with_object({}) do |(key, child), payload|
        payload[key] = canonicalize(child)
      end
    when Array
      value.map { |child| canonicalize(child) }
    when Time, ActiveSupport::TimeWithZone
      value.iso8601
    else
      value
    end
  end

  def mark_running!
    update!(status: 'running', started_at: Time.current)
  end

  def mark_succeeded!(executed_operations:, remote_snapshot: {})
    update!(
      status: 'succeeded',
      executed_operations: executed_operations,
      remote_snapshot: remote_snapshot,
      finished_at: Time.current
    )
  end

  def mark_failed!(error:, executed_operations: [])
    update!(
      status: 'failed',
      error_code: error.respond_to?(:code) ? error.code : error.class.name,
      error_message: error.message,
      error_details: error.respond_to?(:details) ? error.details : {},
      executed_operations: executed_operations,
      finished_at: Time.current
    )
  end

  def mark_blocked!(code:, message:)
    update!(
      status: 'blocked',
      error_code: code,
      error_message: message,
      finished_at: Time.current
    )
  end

  def summary_payload
    {
      id: id,
      operation: operation,
      status: status,
      remote_commit: remote_commit,
      idempotency_key: idempotency_key,
      error_code: error_code,
      error_message: error_message,
      planned_operations_count: Array.wrap(planned_operations).size,
      executed_operations_count: Array.wrap(executed_operations).size,
      started_at: started_at,
      finished_at: finished_at,
      created_at: created_at,
      requested_by_id: requested_by_id
    }.compact
  end

  private

  def normalize_values
    self.operation = operation.to_s.strip.downcase
    self.status = status.to_s.strip.downcase.presence || 'pending'
    self.remote_commit = ActiveModel::Type::Boolean.new.cast(remote_commit)
    self.idempotency_key = idempotency_key.presence || self.class.idempotency_key_for(operation: operation, desired_state: desired_snapshot || {})
    self.desired_snapshot ||= {}
    self.remote_snapshot ||= {}
    self.planned_operations ||= []
    self.executed_operations ||= []
    self.error_details ||= {}
  end

  def sanitize_payloads
    self.desired_snapshot = sanitizer.sanitize(desired_snapshot)
    self.remote_snapshot = sanitizer.sanitize(remote_snapshot)
    self.planned_operations = sanitizer.sanitize(planned_operations)
    self.executed_operations = sanitizer.sanitize(executed_operations)
    self.error_details = sanitizer.sanitize(error_details)
  end

  def sanitizer
    @sanitizer ||= Telephony::VirtualPbx::ConfigBuilder.new(account: nil)
  end
end
