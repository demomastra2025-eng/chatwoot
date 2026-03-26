# == Schema Information
#
# Table name: crm_field_definitions
#
#  id            :bigint           not null, primary key
#  active        :boolean          default(TRUE), not null
#  default_value :jsonb
#  description   :text
#  entity_kind   :string           not null
#  field_type    :string           not null
#  key           :string           not null
#  label         :string           not null
#  options       :jsonb            not null
#  position      :integer          default(0), not null
#  required      :boolean          default(FALSE), not null
#  rules         :jsonb            not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :bigint           not null
#
# Indexes
#
#  index_crm_field_definitions_on_account_entity_active_position  (account_id,entity_kind,active,position)
#  index_crm_field_definitions_on_account_id                      (account_id)
#  index_crm_field_defs_on_account_kind_key                       (account_id,entity_kind,key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class Crm::FieldDefinition < ApplicationRecord
  self.table_name = 'crm_field_definitions'

  ENTITY_KINDS = %w[deal task].freeze
  FIELD_TYPES = %w[text textarea number currency percent checkbox date datetime select multiselect url].freeze
  BUILT_IN_FIELDS = {
    'deal' => %w[
      title description owner_id creator_id team_id company_id originating_conversation_id
      pipeline_id stage_id amount_minor currency expected_close_on closed_at win_probability
      external_ref idempotency_key lock_version archived_at
    ],
    'task' => %w[
      title description deal_id status_id assignee_id creator_id team_id priority
      start_at due_at completed_at external_ref idempotency_key lock_version archived_at
    ]
  }.freeze

  belongs_to :account, class_name: '::Account'

  enum :entity_kind, {
    deal: 'deal',
    task: 'task'
  }, prefix: true

  enum :field_type, FIELD_TYPES.index_with(&:itself), prefix: true

  validates :entity_kind, inclusion: { in: ENTITY_KINDS }
  validates :field_type, inclusion: { in: FIELD_TYPES }
  validates :key, presence: true, uniqueness: { scope: [:account_id, :entity_kind] }
  validates :label, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :key_must_not_conflict_with_built_in_fields
  validate :select_fields_require_options

  scope :ordered, -> { order(:position, :id) }
  scope :active, -> { where(active: true) }
  scope :for_entity_kind, ->(kind) { kind.present? ? where(entity_kind: kind) : all }

  before_validation :normalize_key
  before_validation :normalize_label
  before_validation :assign_position, on: :create

  private

  def assign_position
    return if position.present?
    return if account.blank? || entity_kind.blank?

    self.position = account.crm_field_definitions.where(entity_kind: entity_kind).maximum(:position).to_i + 1
  end

  def key_must_not_conflict_with_built_in_fields
    return if key.blank? || entity_kind.blank?
    return unless BUILT_IN_FIELDS.fetch(entity_kind, []).include?(key)

    errors.add(:key, 'conflicts with a built-in field')
  end

  def normalize_key
    self.key = key.to_s.parameterize(separator: '_')
  end

  def normalize_label
    self.label = label.to_s.strip
  end

  def select_fields_require_options
    return unless field_type_select? || field_type_multiselect?
    return if options.present?

    errors.add(:options, 'must be present for select fields')
  end
end
