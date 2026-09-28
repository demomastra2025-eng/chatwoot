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
#  source         :string           default("system"), not null
#  actor_kind     :string
#  before_data    :jsonb            default({}), not null
#  after_data     :jsonb            default({}), not null
#  causation_id   :uuid
#  schema_version :integer          default(1), not null
#  command_key    :string
#  performed_by_type :string
#  performed_by_id   :bigint
#  published_at       :datetime
#  publication_attempts :integer   default(0), not null
#  publication_error    :text
#  publication_next_attempt_at :datetime default(CURRENT_TIMESTAMP), not null
#
# Indexes
#
#  index_crm_events_on_account_eventable_created_at  (account_id,eventable_type,eventable_id,created_at)
#  index_crm_events_on_account_id_and_correlation_id (account_id,correlation_id)
#  index_crm_events_on_command_dedupe                (account_id,eventable_type,eventable_id,event_type,command_key)
#  index_crm_events_on_account_id                    (account_id)
#  index_crm_events_on_actor_id                      (actor_id)
#  idx_crm_events_ready_for_publication              (publication_next_attempt_at,id)
#  index_crm_events_on_unpublished                   (published_at,id)
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
    deal_waiting_set
    deal_waiting_cleared
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
  PUBLICATION_LEASE = 5.minutes

  belongs_to :account, class_name: '::Account'
  belongs_to :eventable, polymorphic: true
  belongs_to :actor, class_name: '::User', optional: true

  validates :event_type, :source, :correlation_id, :schema_version, presence: true
  validates :schema_version, numericality: { only_integer: true, greater_than: 0 }

  before_validation :prepare_envelope
  after_create :capture_durable_automation_event
  after_create_commit :enqueue_publication

  scope :ordered, -> { order(created_at: :desc, id: :desc) }
  scope :unpublished, -> { where(published_at: nil) }
  scope :ready_for_publication, -> { unpublished.where('publication_next_attempt_at <= ?', Time.current) }

  def readonly?
    persisted? && !@publication_write
  end

  def publish!
    failure = nil
    with_publication_write do
      with_lock do
        next if published_at.present?

        self.publication_attempts += 1
        failure = attempt_listener_dispatch
        save!
      end
    end
    raise failure if failure

    self
  end

  # A persisted lease coalesces callback/replay races and recovers lost jobs.
  # Adapter failures are saved before being raised, not rolled back with them.
  def enqueue_publication!
    failure = nil
    with_publication_write do
      with_lock do
        next if published_at.present? || publication_next_attempt_at > Time.current

        failure = attempt_publication_enqueue
        save!
      end
    end
    raise ActiveJob::EnqueueError.new(failure.message), cause: failure if failure

    self
  end

  private

  def capture_durable_automation_event
    AutomationRules::Events::CrmEventAdapter.new(self).capture!
  end

  def with_publication_write
    @publication_write = true
    yield
  ensure
    @publication_write = false
  end

  def enqueue_publication
    enqueue_publication!
  rescue StandardError => e
    Rails.logger.error("Failed to enqueue CRM event #{id}: #{e.class}: #{e.message}")
  end

  def attempt_publication_enqueue
    Crm::Events::PublishJob.perform_later!(id)
    self.publication_next_attempt_at = PUBLICATION_LEASE.from_now
    nil
  rescue StandardError => e
    self.publication_attempts += 1
    schedule_publication_retry(e)
    e
  end

  def attempt_listener_dispatch
    AutomationRules::Events::CrmEventAdapter.new(self).capture!
    dispatch_automation_event
    self.published_at = Time.current
    self.publication_error = nil
    nil
  rescue StandardError => e
    schedule_publication_retry(e)
    e
  end

  def schedule_publication_retry(error)
    delay = [1.minute * (2**(publication_attempts - 1).clamp(0, 6)), 1.hour].min
    self.publication_next_attempt_at = delay.from_now
    self.publication_error = error.message.to_s.first(2000)
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
    assert_listener_enqueued!(job)
  end

  def assert_listener_enqueued!(job)
    return if job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?

    error = job.enqueue_error if job.respond_to?(:enqueue_error)
    raise error || ActiveJob::EnqueueError.new('CRM event listener dispatch was not enqueued')
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
    normalize_event_payload
    self.publication_next_attempt_at ||= Time.current
    self.source = 'system' if source.blank?
    self.actor_kind ||= actor ? actor.class.base_class.name : 'System'
    self.correlation_id ||= SecureRandom.uuid
    self.schema_version ||= 1
  end

  def normalize_event_payload
    self.meta = {} if meta.blank?
    self.before_data = {} if before_data.blank?
    self.after_data = {} if after_data.blank?
  end

end
