# == Schema Information
#
# Table name: crm_deals
#
#  id                          :bigint           not null, primary key
#  amount_minor                :bigint
#  archived_at                 :datetime
#  closed_at                   :datetime
#  currency                    :string
#  custom_attributes           :jsonb            not null
#  description                 :text
#  expected_close_on           :date
#  external_ref                :string
#  idempotency_key             :string
#  lock_version                :integer          default(0), not null
#  position                    :integer          default(0), not null
#  title                       :string           not null
#  win_probability             :integer
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  account_id                  :bigint           not null
#  company_id                  :bigint
#  creator_id                  :bigint
#  originating_conversation_id :bigint
#  owner_id                    :bigint
#  pipeline_id                 :bigint           not null
#  stage_id                    :bigint           not null
#  team_id                     :bigint
#
# Indexes
#
#  index_crm_deals_on_account_company                   (account_id,company_id)
#  index_crm_deals_on_account_external_ref              (account_id,external_ref) UNIQUE WHERE (external_ref IS NOT NULL)
#  index_crm_deals_on_account_id                        (account_id)
#  index_crm_deals_on_account_idempotency_key           (account_id,idempotency_key) UNIQUE WHERE (idempotency_key IS NOT NULL)
#  index_crm_deals_on_account_originating_conversation  (account_id,originating_conversation_id)
#  index_crm_deals_on_account_stage_position            (account_id,stage_id,position,id)
#  index_crm_deals_on_account_team                      (account_id,team_id)
#  index_crm_deals_on_active_list_dimensions            (account_id,pipeline_id,stage_id,owner_id,expected_close_on) WHERE (archived_at IS NULL)
#  index_crm_deals_on_active_ordering                   (account_id,expected_close_on,updated_at DESC,id DESC) WHERE (archived_at IS NULL)
#  index_crm_deals_on_company_id                        (company_id)
#  index_crm_deals_on_creator_id                        (creator_id)
#  index_crm_deals_on_custom_attributes                 (custom_attributes) USING gin
#  index_crm_deals_on_originating_conversation_id       (originating_conversation_id)
#  index_crm_deals_on_owner_id                          (owner_id)
#  index_crm_deals_on_pipeline_id                       (pipeline_id)
#  index_crm_deals_on_stage_id                          (stage_id)
#  index_crm_deals_on_team_id                           (team_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (company_id => companies.id)
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (originating_conversation_id => conversations.id)
#  fk_rails_...  (owner_id => users.id)
#  fk_rails_...  (pipeline_id => crm_pipelines.id)
#  fk_rails_...  (stage_id => crm_stages.id)
#  fk_rails_...  (team_id => teams.id)
#
class Crm::Deal < ApplicationRecord
  self.table_name = 'crm_deals'

  include LlmFormattable

  belongs_to :account, class_name: '::Account'
  belongs_to :pipeline, class_name: '::Crm::Pipeline'
  belongs_to :stage, class_name: '::Crm::Stage'
  belongs_to :owner, class_name: '::User', optional: true
  belongs_to :creator, class_name: '::User', optional: true
  belongs_to :team, class_name: '::Team', optional: true
  belongs_to :company, class_name: '::Company', optional: true
  belongs_to :originating_conversation, class_name: '::Conversation', optional: true

  has_many :deal_contacts,
           -> { ordered },
           class_name: '::Crm::DealContact',
           dependent: :destroy_async,
           inverse_of: :deal
  has_many :contacts, through: :deal_contacts
  has_many :tasks, class_name: '::Crm::Task', dependent: :nullify, inverse_of: :deal
  has_many :events, as: :eventable, class_name: '::Crm::Event', dependent: :destroy_async
  has_many :comments, as: :commentable, class_name: '::Crm::Comment', dependent: :destroy_async
  has_many :reminders, as: :remindable, dependent: :nullify

  validates :title, presence: true
  validates :external_ref, uniqueness: { scope: :account_id }, allow_blank: true
  validates :idempotency_key, uniqueness: { scope: :account_id }, allow_blank: true
  validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :win_probability, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :custom_attributes, jsonb_attributes_length: true
  validate :stage_belongs_to_pipeline
  validate :related_records_belong_to_account
  validate :currency_required_when_amount_present

  scope :ordered, -> { order(expected_close_on: :asc, updated_at: :desc, id: :desc) }
  scope :kept, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  before_validation :normalize_title
  before_validation :normalize_description
  before_validation :normalize_currency
  before_validation :prepare_custom_attributes
  before_validation :assign_position, on: :create

  def primary_contact_id
    deal_contacts.find(&:primary?)&.contact_id
  end

  def closed?
    closed_at.present?
  end

  def automation_webhook_data
    payload = {
      account: account.webhook_data,
      deal: {
        id: id,
        title: title,
        description: description,
        amount_minor: amount_minor,
        currency: currency,
        expected_close_on: expected_close_on,
        win_probability: win_probability,
        closed_at: closed_at,
        external_ref: external_ref,
        pipeline_id: pipeline_id,
        stage_id: stage_id,
        owner_id: owner_id,
        creator_id: creator_id,
        team_id: team_id,
        company_id: company_id,
        originating_conversation_id: originating_conversation_id,
        primary_contact_id: primary_contact_id,
        archived_at: archived_at,
        custom_attributes: custom_attributes
      },
      pipeline: {
        id: pipeline.id,
        name: pipeline.name
      },
      stage: {
        id: stage.id,
        name: stage.name,
        outcome: stage.outcome
      }
    }

    payload[:owner] = owner.webhook_data if owner.present?
    payload[:creator] = creator.webhook_data if creator.present?
    payload[:team] = { id: team.id, name: team.name } if team.present?
    payload[:company] = { id: company.id, name: company.name, domain: company.domain } if company.present?
    payload[:conversation] = originating_conversation.webhook_data if originating_conversation.present?
    payload[:contacts] = contacts.map(&:webhook_data) if contacts.exists?

    payload
  end

  private

  def currency_required_when_amount_present
    return if amount_minor.blank? || currency.present?

    errors.add(:currency, 'must be present when amount_minor is set')
  end

  def normalize_currency
    self.currency = currency.to_s.strip.upcase.presence
  end

  def normalize_description
    self.description = description.to_s.strip.presence
  end

  def normalize_title
    self.title = title.to_s.strip
  end

  def prepare_custom_attributes
    self.custom_attributes = {} if custom_attributes.blank?
  end

  def assign_position
    return if stage.blank?
    return if position.present? && position.to_i.positive?

    self.position = stage.deals.kept.maximum(:position).to_i + 1
  end

  def related_records_belong_to_account
    validate_account_match(:pipeline, pipeline)
    validate_account_match(:stage, stage)
    validate_account_match(:owner, owner)
    validate_account_match(:creator, creator)
    validate_account_match(:team, team)
    validate_account_match(:company, company)
    validate_account_match(:originating_conversation, originating_conversation)
  end

  def stage_belongs_to_pipeline
    return if stage.blank? || pipeline.blank?
    return if stage.pipeline_id == pipeline_id

    errors.add(:stage_id, 'must belong to the selected pipeline')
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
