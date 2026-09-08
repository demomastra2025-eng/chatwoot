# == Schema Information
#
# Table name: crm_events
#
#  id                   :bigint           not null, primary key
#  actor_kind           :string
#  after_data           :jsonb            not null
#  before_data          :jsonb            not null
#  command_key          :string
#  event_type           :string           not null
#  eventable_type       :string           not null
#  meta                 :jsonb            not null
#  performed_by_type    :string
#  publication_attempts :integer          default(0), not null
#  publication_error    :text
#  published_at         :datetime
#  schema_version       :integer          default(1), not null
#  source               :string           default("system"), not null
#  created_at           :datetime         not null
#  account_id           :bigint           not null
#  actor_id             :bigint
#  causation_id         :uuid
#  correlation_id       :uuid             not null
#  eventable_id         :bigint           not null
#  performed_by_id      :bigint
#
# Indexes
#
#  index_crm_events_on_account_eventable_created_at   (account_id,eventable_type,eventable_id,created_at)
#  index_crm_events_on_account_id                     (account_id)
#  index_crm_events_on_account_id_and_correlation_id  (account_id,correlation_id)
#  index_crm_events_on_actor_id                       (actor_id)
#  index_crm_events_on_command_dedupe                 (account_id,eventable_type,eventable_id,event_type,command_key) UNIQUE WHERE (command_key IS NOT NULL)
#  index_crm_events_on_unpublished                    (published_at,id) WHERE (published_at IS NULL)
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
    task_assigned
    task_rescheduled
    task_completed
    task_cancelled
    task_reopened
    task_waiting_changed
    task_archived
    task_unarchived
  ].freeze
  PERFORMED_BY_TYPES = %w[AutomationRule Captain::Assistant User].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :eventable, polymorphic: true
  belongs_to :actor, class_name: '::User', optional: true

  validates :event_type, :source, :correlation_id, :schema_version, presence: true
  validates :schema_version, numericality: { only_integer: true, greater_than: 0 }

  before_validation :prepare_envelope
  after_create_commit :enqueue_publication

  scope :ordered, -> { order(created_at: :desc, id: :desc) }
  scope :unpublished, -> { where(published_at: nil) }

  def readonly?
    persisted? && !@publication_write
  end

  def publish!
    with_publication_write do
      with_lock do
        if published_at.blank?
          self.publication_attempts += 1
          dispatch_automation_event
          update!(published_at: Time.current, publication_error: nil)
        end
      end
    end
    self
  rescue StandardError => e
    record_publication_failure!(e)
    raise
  end

  private

  def with_publication_write
    @publication_write = true
    yield
  ensure
    @publication_write = false
  end

  def enqueue_publication
    Crm::Events::PublishJob.perform_later!(id)
  rescue ActiveJob::EnqueueError => e
    with_publication_write { update!(publication_error: e.message.to_s.first(2000)) }
    Rails.logger.error("Failed to enqueue CRM event #{id}: #{e.class}: #{e.message}")
  end

  def dispatch_automation_event
    key = eventable_payload_key
    return if key.blank? || event_type.blank? || !event_type.in?(SUPPORTED_AUTOMATION_EVENT_TYPES)

    event_data = {
      account: account,
      crm_event: self,
      changed_attributes: meta.with_indifferent_access[:changes],
      performed_by: performed_by_record
    }.merge(key => eventable)
    job = Rails.configuration.dispatcher.dispatch(event_type, created_at || Time.zone.now, event_data)
    return unless job.respond_to?(:successfully_enqueued?) && !job.successfully_enqueued?

    raise job.enqueue_error || ActiveJob::EnqueueError.new('CRM event listener dispatch was not enqueued')
  end

  def record_publication_failure!(error)
    with_publication_write do
      reload
      update!(
        publication_attempts: publication_attempts + 1,
        publication_error: error.message.to_s.first(2000)
      )
    end
  end

  def performed_by_record
    return if performed_by_type.blank? || performed_by_id.blank?
    return unless performed_by_type.in?(PERFORMED_BY_TYPES)

    performed_by_type.constantize.find_by(id: performed_by_id)
  end

  def eventable_payload_key
    case eventable
    when ::Crm::Deal
      :deal
    when ::Crm::Task
      :task
    end
  end

  def prepare_envelope
    self.meta = {} if meta.blank?
    self.before_data = {} if before_data.blank?
    self.after_data = {} if after_data.blank?
    self.source = 'system' if source.blank?
    self.actor_kind ||= actor&.class&.base_class&.name || 'System'
    self.correlation_id ||= SecureRandom.uuid
    self.schema_version ||= 1
  end
end
