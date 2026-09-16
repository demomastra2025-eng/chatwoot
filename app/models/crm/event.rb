# == Schema Information
#
# Table name: crm_events
#
#  id             :bigint           not null, primary key
#  event_type     :string           not null
#  eventable_type :string           not null
#  meta           :jsonb            not null
#  correlation_id :uuid             default("gen_random_uuid()"), not null
#  created_at     :datetime         not null
#  account_id     :bigint           not null
#  actor_id       :bigint
#  eventable_id   :bigint           not null
#
# Indexes
#
#  index_crm_events_on_account_eventable_created_at  (account_id,eventable_type,eventable_id,created_at)
#  index_crm_events_on_account_id                    (account_id)
#  index_crm_events_on_actor_id                      (actor_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (actor_id => users.id)
#
class Crm::Event < ApplicationRecord
  self.table_name = 'crm_events'

  SUPPORTED_AUTOMATION_EVENT_TYPES = %w[
    deal_created
    deal_updated
    deal_stage_changed
    deal_archived
    deal_unarchived
    task_created
    task_updated
    task_status_changed
    task_archived
    task_unarchived
  ].freeze

  attr_accessor :performed_by

  belongs_to :account, class_name: '::Account'
  belongs_to :eventable, polymorphic: true
  belongs_to :actor, class_name: '::User', optional: true

  validates :event_type, presence: true

  before_validation :prepare_meta
  before_validation :prepare_correlation_id
  after_create_commit :dispatch_automation_event

  scope :ordered, -> { order(created_at: :desc, id: :desc) }

  private

  def dispatch_automation_event
    key = eventable_payload_key
    return if key.blank? || event_type.blank? || !event_type.in?(SUPPORTED_AUTOMATION_EVENT_TYPES)

    event_data = {
      account: account,
      crm_event: self,
      changed_attributes: meta.with_indifferent_access[:changes],
      performed_by: performed_by
    }
    event_data[key] = eventable

    Rails.configuration.dispatcher.dispatch(
      event_type,
      created_at || Time.zone.now,
      event_data
    )
  end

  def eventable_payload_key
    case eventable
    when ::Crm::Deal
      :deal
    when ::Crm::Task
      :task
    end
  end

  def prepare_meta
    self.meta = {} if meta.blank?
  end

  def prepare_correlation_id
    return unless has_attribute?(:correlation_id)

    self.correlation_id ||= SecureRandom.uuid
  end
end
