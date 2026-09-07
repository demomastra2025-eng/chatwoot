# == Schema Information
#
# Table name: crm_tasks
#
#  id                          :bigint           not null, primary key
#  activity_type               :string           default("task"), not null
#  all_day                     :boolean          default(FALSE), not null
#  archived_at                 :datetime
#  completed_at                :datetime
#  custom_attributes           :jsonb            not null
#  description                 :text
#  due_at                      :datetime
#  due_on                      :date
#  external_ref                :string
#  idempotency_key             :string
#  lock_version                :integer          default(0), not null
#  outcome                     :string
#  outcome_note                :text
#  position                    :integer          default(0), not null
#  priority                    :string           default("medium"), not null
#  schedule_timezone           :string           default("Asia/Almaty"), not null
#  start_at                    :datetime
#  title                       :string           not null
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  account_id                  :bigint           not null
#  assignee_id                 :bigint
#  creator_id                  :bigint
#  deal_id                     :bigint
#  originating_conversation_id :bigint
#  status_id                   :bigint           not null
#  team_id                     :bigint
#
# Indexes
#
#  index_crm_tasks_on_account_activity_type_due_at      (account_id,activity_type,due_at)
#  index_crm_tasks_on_account_deal                      (account_id,deal_id)
#  index_crm_tasks_on_account_deal_activity_type        (account_id,deal_id,activity_type)
#  index_crm_tasks_on_active_due_on                      (account_id,due_on) WHERE (archived_at IS NULL)
#  index_crm_tasks_on_account_external_ref              (account_id,external_ref) UNIQUE WHERE (external_ref IS NOT NULL)
#  index_crm_tasks_on_account_id                        (account_id)
#  index_crm_tasks_on_account_idempotency_key           (account_id,idempotency_key) UNIQUE WHERE (idempotency_key IS NOT NULL)
#  index_crm_tasks_on_account_originating_conversation  (account_id,originating_conversation_id)
#  index_crm_tasks_on_account_status_position           (account_id,status_id,position,id)
#  index_crm_tasks_on_account_team                      (account_id,team_id)
#  index_crm_tasks_on_active_list_dimensions            (account_id,status_id,assignee_id,due_at) WHERE (archived_at IS NULL)
#  index_crm_tasks_on_active_ordering                   (account_id,due_at,updated_at DESC,id DESC) WHERE (archived_at IS NULL)
#  index_crm_tasks_on_assignee_id                       (assignee_id)
#  index_crm_tasks_on_creator_id                        (creator_id)
#  index_crm_tasks_on_custom_attributes                 (custom_attributes) USING gin
#  index_crm_tasks_on_deal_id                           (deal_id)
#  index_crm_tasks_on_originating_conversation_id       (originating_conversation_id)
#  index_crm_tasks_on_status_id                         (status_id)
#  index_crm_tasks_on_team_id                           (team_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (assignee_id => users.id)
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (deal_id => crm_deals.id)
#  fk_rails_...  (originating_conversation_id => conversations.id)
#  fk_rails_...  (status_id => crm_task_statuses.id)
#  fk_rails_...  (team_id => teams.id)
#
class Crm::Task < ApplicationRecord
  self.table_name = 'crm_tasks'

  include LlmFormattable

  ACTIVITY_TYPES = %w[task call meeting message touch].freeze
  OUTCOMES = %w[
    completed held cancelled no_show rescheduled answered no_answer not_done busy sent failed
  ].freeze
  PRIORITIES = %w[low medium high urgent].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :deal, class_name: '::Crm::Deal', optional: true, inverse_of: :tasks
  belongs_to :status, class_name: '::Crm::TaskStatus'
  belongs_to :task_type, class_name: '::Crm::TaskType', inverse_of: :tasks
  belongs_to :task_outcome, class_name: '::Crm::TaskOutcome', inverse_of: :tasks, optional: true
  belongs_to :assignee, class_name: '::User', optional: true
  belongs_to :creator, class_name: '::User', optional: true
  belongs_to :completed_by, class_name: '::User', optional: true
  belongs_to :cancelled_by, class_name: '::User', optional: true
  belongs_to :team, class_name: '::Team', optional: true
  belongs_to :originating_conversation, class_name: '::Conversation', optional: true

  has_many :events, as: :eventable, class_name: '::Crm::Event', dependent: :restrict_with_error
  has_many :comments, as: :commentable, class_name: '::Crm::Comment', dependent: :destroy_async
  has_many :reminders, as: :remindable, dependent: :nullify

  enum :priority, PRIORITIES.index_with(&:itself), prefix: true

  validates :title, presence: true
  validates :activity_type, presence: true
  validates :outcome_note, presence: true, if: :outcome_note_required?
  validates :priority, inclusion: { in: PRIORITIES }
  validates :external_ref, uniqueness: { scope: :account_id }, allow_blank: true
  validates :idempotency_key, uniqueness: { scope: :account_id }, allow_blank: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :reschedule_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :schedule_timezone, inclusion: { in: TZInfo::Timezone.all_identifiers }
  validates :due_on, presence: true, if: :all_day?
  validates :custom_attributes, jsonb_attributes_length: true
  validate :related_records_belong_to_account

  scope :ordered, lambda {
    order(Arel.sql('COALESCE(crm_tasks.due_at, crm_tasks.due_on::timestamp) ASC NULLS LAST'))
      .order(updated_at: :desc, id: :desc)
  }
  scope :kept, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  before_validation :normalize_activity_type
  before_validation :normalize_outcome
  before_validation :normalize_outcome_note
  before_validation :sync_catalog_snapshots
  before_validation :normalize_title
  before_validation :normalize_description
  before_validation :normalize_schedule
  before_validation :prepare_custom_attributes
  before_validation :assign_position, on: :create
  after_commit :sync_contact_owner_from_assignee, if: :saved_change_to_assignee_id?

  def automation_webhook_data
    Crm::AutomationPayloadBuilder.task(self)
  end

  def effective_due_at
    return due_at if due_at.present?
    return if due_on.blank?

    zone = Time.find_zone(schedule_timezone) || Time.zone
    zone.local(due_on.year, due_on.month, due_on.day).end_of_day
  end

  def completed?
    completed_at.present?
  end

  def cancelled?
    cancelled_at.present?
  end

  private

  def normalize_schedule
    self.schedule_timezone = schedule_timezone.presence || account&.workspace_working_hours_timezone ||
                             AccountWorkspaceWorkingHours::DEFAULT_TIMEZONE
    return self.due_on = nil unless all_day?

    normalize_all_day_due_on
    self.start_at = nil
    self.due_at = nil
  end

  def normalize_all_day_due_on
    zone = Time.find_zone(schedule_timezone)
    return unless due_at.present? && zone.present?
    return if due_on.present?

    self.due_on = due_at.in_time_zone(zone).to_date
  end

  def normalize_activity_type
    self.activity_type = activity_type.to_s.strip.downcase.presence || 'task'
  end

  def sync_catalog_snapshots
    self.activity_type = task_type.code if task_type.present?
    self.outcome = task_outcome.code if task_outcome.present?
  end

  def outcome_note_required?
    outcome == 'not_done' || task_outcome&.requires_note?
  end

  def normalize_description
    self.description = description.to_s.strip.presence
  end

  def normalize_outcome
    self.outcome = outcome.to_s.strip.downcase.presence
  end

  def normalize_outcome_note
    self.outcome_note = outcome_note.to_s.strip.presence
  end

  def normalize_title
    self.title = title.to_s.strip
  end

  def prepare_custom_attributes
    self.custom_attributes = {} if custom_attributes.blank?
  end

  def assign_position
    return if status.blank?
    return if position.present? && position.to_i.positive?

    self.position = status.tasks.kept.maximum(:position).to_i + 1
  end

  def related_records_belong_to_account
    validate_account_match(:deal, deal)
    validate_account_match(:status, status)
    validate_account_match(:task_type, task_type)
    validate_account_match(:task_outcome, task_outcome)
    validate_account_match(:assignee, assignee)
    validate_account_match(:creator, creator)
    validate_account_match(:team, team)
    validate_account_match(:originating_conversation, originating_conversation)
    return if task_outcome.blank? || task_outcome.task_type_id == task_type_id

    errors.add(:task_outcome, 'must belong to the selected task type')
  end

  def validate_account_match(attribute_name, record)
    return if record.blank? || record_belongs_to_account?(record)
    return if persisted? && !will_save_change_to_attribute?("#{attribute_name}_id")

    errors.add(attribute_name, 'must belong to the current account')
  end

  def record_belongs_to_account?(record)
    return account.users.exists?(id: record.id) if record.is_a?(User)
    return false unless record.respond_to?(:account_id)

    record.account_id == account_id
  end

  def sync_contact_owner_from_assignee
    contact = owner_sync_contact
    return if contact.blank? || contact.owner_id == assignee_id
    return if assignee_id.present? && !account.users.exists?(id: assignee_id)

    contact.update!(owner_id: assignee_id)
  end

  def owner_sync_contact
    deal&.primary_contact || originating_conversation&.contact
  end
end
