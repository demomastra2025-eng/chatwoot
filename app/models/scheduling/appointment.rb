# == Schema Information
#
# Table name: scheduling_appointments
#
#  id                            :bigint           not null, primary key
#  appointment_type              :string           default("primary"), not null
#  client_birth_date             :date
#  client_comment                :text
#  client_gender                 :string
#  client_identifier             :string
#  client_name                   :string           not null
#  client_phone                  :string
#  compensation_percent_snapshot :integer          default(0), not null
#  compensation_type_snapshot    :string
#  compensation_value_snapshot   :integer
#  custom_attributes             :jsonb            not null
#  duration_min                  :integer          default(30), not null
#  ends_at                       :datetime         not null
#  external_ref                  :string
#  idempotency_key               :string
#  payment_status                :string           default("awaiting_payment"), not null
#  prepaid_amount                :integer          default(0), not null
#  prepaid_payment_method        :string
#  service_amount                :integer          default(0), not null
#  service_duration_min_snapshot :integer
#  service_name_snapshot         :string
#  service_type_snapshot         :string
#  settlement_amount             :integer          default(0), not null
#  settlement_payment_method     :string
#  source                        :string           default("manual"), not null
#  starts_at                     :datetime         not null
#  status                        :string           default("scheduled"), not null
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
#  account_id                    :bigint           not null
#  company_id                    :bigint
#  contact_id                    :bigint
#  conversation_id               :bigint
#  created_by_id                 :bigint
#  resource_id                   :bigint           not null
#  service_id                    :bigint
#
# Indexes
#
#  idx_scheduling_appointments_on_account_external_ref     (account_id,external_ref) UNIQUE WHERE (external_ref IS NOT NULL)
#  idx_scheduling_appointments_on_account_idempotency_key  (account_id,idempotency_key) UNIQUE WHERE (idempotency_key IS NOT NULL)
#  idx_scheduling_appointments_on_account_resource_range   (account_id,resource_id,starts_at,ends_at)
#  idx_scheduling_appointments_on_account_starts_at        (account_id,starts_at)
#  index_scheduling_appointments_on_account_id             (account_id)
#  index_scheduling_appointments_on_company_id             (company_id)
#  index_scheduling_appointments_on_contact_id             (contact_id)
#  index_scheduling_appointments_on_conversation_id        (conversation_id)
#  index_scheduling_appointments_on_created_by_id          (created_by_id)
#  index_scheduling_appointments_on_resource_id            (resource_id)
#  index_scheduling_appointments_on_service_id             (service_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (company_id => companies.id)
#  fk_rails_...  (contact_id => contacts.id)
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (created_by_id => users.id)
#  fk_rails_...  (resource_id => scheduling_resources.id)
#  fk_rails_...  (service_id => scheduling_services.id)
#

class Scheduling::Appointment < ApplicationRecord
  include LlmFormattable

  after_create_commit :dispatch_created_event
  after_update_commit :dispatch_updated_events

  belongs_to :account
  belongs_to :company, optional: true
  belongs_to :contact, optional: true
  belongs_to :conversation, optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :resource, class_name: 'Scheduling::Resource', inverse_of: :appointments
  belongs_to :service, class_name: 'Scheduling::Service', optional: true, inverse_of: :appointments

  has_one :expense, class_name: 'Scheduling::Expense', dependent: :destroy_async, inverse_of: :appointment
  has_many :payments, -> { order(:created_at, :id) }, class_name: 'Scheduling::Payment', dependent: :destroy_async, inverse_of: :appointment

  before_validation :sync_account_id
  before_validation :assign_duration_min

  validates :client_name, :starts_at, :ends_at, :source, presence: true
  validates :status, inclusion: { in: Scheduling::Constants::APPOINTMENT_STATUSES }
  validates :appointment_type, inclusion: { in: Scheduling::Constants::APPOINTMENT_TYPES }
  validates :payment_status, inclusion: { in: Scheduling::Constants::PAYMENT_STATUSES }
  validates :prepaid_payment_method, inclusion: { in: Scheduling::Constants::PAYMENT_METHODS }, allow_blank: true
  validates :settlement_payment_method, inclusion: { in: Scheduling::Constants::PAYMENT_METHODS }, allow_blank: true
  validates :compensation_type_snapshot, inclusion: { in: Scheduling::Constants::COMPENSATION_TYPES }, allow_blank: true
  validates :duration_min, inclusion: { in: 5..720 }
  validates :service_amount, :prepaid_amount, :settlement_amount, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :compensation_percent_snapshot, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :external_ref, uniqueness: { scope: :account_id }, allow_blank: true
  validates :idempotency_key, uniqueness: { scope: :account_id }, allow_blank: true
  validate :ends_after_starts
  validate :total_received_within_service_amount
  validate :payment_methods_present_for_positive_amounts
  validate :associations_belong_to_account
  validate :compensation_snapshot_percent_within_range
  validate :combined_compensation_snapshot_percent_within_range

  scope :ordered, -> { order(:starts_at, :id) }
  scope :active_statuses, -> { where.not(status: 'cancelled') }

  def manual_payments_total
    payments.where(payment_kind: 'payment').sum(:amount)
  end

  def automation_webhook_data
    payload = {
      account: account.webhook_data,
      appointment: {
        id: id,
        starts_at: starts_at&.iso8601,
        ends_at: ends_at&.iso8601,
        duration_min: duration_min,
        status: status,
        payment_status: payment_status,
        appointment_type: appointment_type,
        source: source,
        client_name: client_name,
        client_phone: client_phone,
        client_identifier: client_identifier,
        service_amount: service_amount,
        prepaid_amount: prepaid_amount,
        settlement_amount: settlement_amount,
        contact_id: contact_id,
        company_id: company_id,
        conversation_id: conversation_id,
        resource_id: resource_id,
        service_id: service_id,
        custom_attributes: custom_attributes
      },
      resource: {
        id: resource.id,
        name: resource.name
      }
    }

    payload[:contact] = contact.webhook_data if contact.present?
    payload[:company] = { id: company.id, name: company.name, domain: company.domain } if company.present?
    payload[:conversation] = conversation.webhook_data if conversation.present?
    payload[:service] = { id: service.id, name: service.name } if service.present?
    payload[:created_by] = created_by.webhook_data if created_by.present?

    payload
  end

  private

  def changed_attributes_payload
    previous_changes.except('updated_at', :updated_at)
  end

  def dispatch_created_event
    Rails.configuration.dispatcher.dispatch(
      APPOINTMENT_CREATED,
      Time.zone.now,
      appointment: self,
      performed_by: Current.executed_by
    )
  end

  def dispatch_updated_events
    changed_attributes = changed_attributes_payload
    return if changed_attributes.blank?

    Rails.configuration.dispatcher.dispatch(
      APPOINTMENT_UPDATED,
      Time.zone.now,
      appointment: self,
      performed_by: Current.executed_by,
      changed_attributes: changed_attributes
    )

    dispatch_status_event(changed_attributes) if saved_change_to_status?
  end

  def dispatch_status_event(changed_attributes)
    event_name =
      case status
      when 'cancelled'
        APPOINTMENT_CANCELLED
      when 'completed'
        APPOINTMENT_COMPLETED
      end

    return if event_name.blank?

    Rails.configuration.dispatcher.dispatch(
      event_name,
      Time.zone.now,
      appointment: self,
      performed_by: Current.executed_by,
      changed_attributes: changed_attributes
    )
  end

  def assign_duration_min
    return if starts_at.blank? || ends_at.blank?

    self.duration_min = [((ends_at - starts_at) / 60).round, 5].max if duration_min.blank? || duration_min.to_i <= 0
  end

  def associations_belong_to_account
    {
      company: company,
      contact: contact,
      conversation: conversation,
      created_by: created_by,
      service: service
    }.each do |name, record|
      next if record.blank?
      next if record_belongs_to_account?(record)

      errors.add(:"#{name}_id", 'must belong to the current account')
    end
  end

  def record_belongs_to_account?(record)
    return account.users.exists?(id: record.id) if record.is_a?(User)
    return false unless record.respond_to?(:account_id)

    record.account_id == account_id
  end

  def compensation_snapshot_percent_within_range
    return unless compensation_type_snapshot == 'percent'
    return if compensation_value_snapshot.to_i.between?(0, 100)

    errors.add(:compensation_value_snapshot, 'must be between 0 and 100 for percent compensation')
  end

  def combined_compensation_snapshot_percent_within_range
    return unless compensation_type_snapshot == 'fixed_plus_percent'
    return if compensation_percent_snapshot.to_i.between?(0, 100)

    errors.add(:compensation_percent_snapshot, 'must be between 0 and 100 for fixed plus percent compensation')
  end

  def ends_after_starts
    return if starts_at.blank? || ends_at.blank?
    return if ends_at > starts_at

    errors.add(:ends_at, 'must be after starts_at')
  end

  def payment_methods_present_for_positive_amounts
    if prepaid_amount.to_i.positive? && prepaid_payment_method.blank?
      errors.add(:prepaid_payment_method, 'must be present when prepaid_amount is greater than 0')
    end
    return unless settlement_amount.to_i.positive? && settlement_payment_method.blank?

    errors.add(:settlement_payment_method, 'must be present when settlement_amount is greater than 0')
  end

  def sync_account_id
    self.account_id = resource.account_id if resource.present?
  end

  def total_received_within_service_amount
    return unless service_amount.to_i.positive?
    return if prepaid_amount.to_i + settlement_amount.to_i <= service_amount.to_i

    errors.add(:base, 'total received amount cannot exceed service_amount')
  end
end
