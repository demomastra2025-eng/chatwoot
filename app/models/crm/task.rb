# == Schema Information
#
# Table name: crm_tasks
#
#  id                          :bigint           not null, primary key
#  archived_at                 :datetime
#  completed_at                :datetime
#  custom_attributes           :jsonb            not null
#  description                 :text
#  due_at                      :datetime
#  external_ref                :string
#  idempotency_key             :string
#  lock_version                :integer          default(0), not null
#  priority                    :string           default("medium"), not null
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
#  index_crm_tasks_on_account_deal                      (account_id,deal_id)
#  index_crm_tasks_on_account_external_ref              (account_id,external_ref) UNIQUE WHERE (external_ref IS NOT NULL)
#  index_crm_tasks_on_account_id                        (account_id)
#  index_crm_tasks_on_account_idempotency_key           (account_id,idempotency_key) UNIQUE WHERE (idempotency_key IS NOT NULL)
#  index_crm_tasks_on_account_originating_conversation  (account_id,originating_conversation_id)
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

  PRIORITIES = %w[low medium high urgent].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :deal, class_name: '::Crm::Deal', optional: true, inverse_of: :tasks
  belongs_to :status, class_name: '::Crm::TaskStatus'
  belongs_to :assignee, class_name: '::User', optional: true
  belongs_to :creator, class_name: '::User', optional: true
  belongs_to :team, class_name: '::Team', optional: true
  belongs_to :originating_conversation, class_name: '::Conversation', optional: true

  has_many :events, as: :eventable, class_name: '::Crm::Event', dependent: :destroy_async
  has_many :comments, as: :commentable, class_name: '::Crm::Comment', dependent: :destroy_async

  enum :priority, PRIORITIES.index_with(&:itself), prefix: true

  validates :title, presence: true
  validates :priority, inclusion: { in: PRIORITIES }
  validates :external_ref, uniqueness: { scope: :account_id }, allow_blank: true
  validates :idempotency_key, uniqueness: { scope: :account_id }, allow_blank: true
  validates :custom_attributes, jsonb_attributes_length: true
  validate :related_records_belong_to_account

  scope :ordered, -> { order(due_at: :asc, updated_at: :desc, id: :desc) }
  scope :kept, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  before_validation :normalize_title
  before_validation :normalize_description
  before_validation :prepare_custom_attributes

  def automation_webhook_data
    payload = {
      account: account.webhook_data,
      task: {
        id: id,
        title: title,
        description: description,
        priority: priority,
        start_at: start_at,
        due_at: due_at,
        completed_at: completed_at,
        external_ref: external_ref,
        status_id: status_id,
        assignee_id: assignee_id,
        creator_id: creator_id,
        team_id: team_id,
        deal_id: deal_id,
        originating_conversation_id: originating_conversation_id,
        archived_at: archived_at,
        custom_attributes: custom_attributes
      },
      status: {
        id: status.id,
        name: status.name,
        category: status.category
      }
    }

    payload[:assignee] = assignee.webhook_data if assignee.present?
    payload[:creator] = creator.webhook_data if creator.present?
    payload[:team] = { id: team.id, name: team.name } if team.present?
    payload[:deal] = { id: deal.id, title: deal.title } if deal.present?
    payload[:conversation] = originating_conversation.webhook_data if originating_conversation.present?

    payload
  end

  private

  def normalize_description
    self.description = description.to_s.strip.presence
  end

  def normalize_title
    self.title = title.to_s.strip
  end

  def prepare_custom_attributes
    self.custom_attributes = {} if custom_attributes.blank?
  end

  def related_records_belong_to_account
    validate_account_match(:deal, deal)
    validate_account_match(:status, status)
    validate_account_match(:assignee, assignee)
    validate_account_match(:creator, creator)
    validate_account_match(:team, team)
    validate_account_match(:originating_conversation, originating_conversation)
  end

  def validate_account_match(attribute_name, record)
    return if record.blank? || record_belongs_to_account?(record)

    errors.add(attribute_name, 'must belong to the current account')
  end

  def record_belongs_to_account?(record)
    return account.users.exists?(id: record.id) if record.is_a?(User)
    return false unless record.respond_to?(:account_id)

    record.account_id == account_id
  end
end
