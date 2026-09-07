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

  ENTITY_KINDS = %w[deal task appointment].freeze
  FIELD_TYPES = %w[text textarea number currency percent checkbox date datetime select multiselect url].freeze
  SYSTEM_FIELD_DEFINITIONS = {
    'deal' => {
      'source' => {
        label: 'Источник',
        field_type: 'select',
        active: true,
        required: false,
        default_value: nil,
        options: [
          { label: 'Вручную', value: 'manual' },
          { label: 'Диалог', value: 'conversation' },
          { label: 'AI', value: 'ai' },
          { label: 'Импорт', value: 'import' },
          { label: 'Другое', value: 'other' }
        ],
        rules: {}
      }
    }
  }.freeze
  BUILT_IN_FIELDS = {
    'deal' => %w[
      title description owner_id creator_id team_id company_id originating_conversation_id
      pipeline_id stage_id amount_minor currency expected_close_on closed_at win_probability
      external_ref idempotency_key lock_version archived_at
    ],
    'task' => %w[
      title description deal_id status_id assignee_id creator_id team_id activity_type outcome outcome_note priority
      start_at due_at completed_at external_ref idempotency_key lock_version archived_at
    ],
    'appointment' => %w[
      resource_id contact_id service_id company_id conversation_id created_by_id owner_id
      starts_at ends_at duration_min status appointment_type client_name client_first_name
      client_last_name client_middle_name client_phone
      client_identifier client_birth_date client_gender client_comment source
      external_ref idempotency_key service_name_snapshot service_type_snapshot
      service_duration_min_snapshot service_amount compensation_type_snapshot
      compensation_value_snapshot compensation_percent_snapshot prepaid_amount
      prepaid_payment_method settlement_amount settlement_payment_method
      payment_status
    ]
  }.freeze
  RESERVED_CUSTOM_ATTRIBUTE_KEYS = {
    'appointment' => %w[service_ids services source_mode]
  }.freeze
  RESERVED_CUSTOM_ATTRIBUTE_PREFIXES = {
    'appointment' => %w[medelement_]
  }.freeze

  belongs_to :account, class_name: '::Account'
  has_many :stage_field_requirements,
           class_name: '::Crm::StageFieldRequirement',
           dependent: :destroy,
           inverse_of: :field_definition

  enum :entity_kind, {
    deal: 'deal',
    task: 'task',
    appointment: 'appointment'
  }, prefix: true

  enum :field_type, FIELD_TYPES.index_with(&:itself), prefix: true

  validates :entity_kind, inclusion: { in: ENTITY_KINDS }
  validates :field_type, inclusion: { in: FIELD_TYPES }
  validates :key, presence: true, uniqueness: { scope: [:account_id, :entity_kind] }
  validates :label, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :key_must_not_conflict_with_built_in_fields
  validate :key_must_not_conflict_with_reserved_custom_attributes
  validate :select_fields_require_options
  validate :system_field_identity_must_not_change, on: :update

  scope :ordered, -> { order(:position, :id) }
  scope :active, -> { where(active: true) }
  scope :for_entity_kind, ->(kind) { kind.present? ? where(entity_kind: kind) : all }

  before_validation :normalize_key
  before_validation :normalize_label
  before_validation :assign_position, on: :create
  before_destroy :prevent_system_field_destroy

  class << self
    def system_definition_for(entity_kind, key)
      SYSTEM_FIELD_DEFINITIONS.dig(entity_kind.to_s, key.to_s)
    end

    def system_field_key?(entity_kind, key)
      system_definition_for(entity_kind, key).present?
    end
  end

  def system?
    self.class.system_field_key?(entity_kind, key)
  end

  def persisted_system_field?
    return false unless persisted?

    definition = self.class.system_definition_for(
      entity_kind_in_database || entity_kind,
      key_in_database || key
    )
    return false if definition.blank?

    (field_type_in_database || field_type).to_s == definition[:field_type].to_s
  end

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

  def key_must_not_conflict_with_reserved_custom_attributes
    return if key.blank? || entity_kind.blank?

    reserved_keys = RESERVED_CUSTOM_ATTRIBUTE_KEYS.fetch(entity_kind, [])
    reserved_prefixes = RESERVED_CUSTOM_ATTRIBUTE_PREFIXES.fetch(entity_kind, [])
    return unless reserved_keys.include?(key) || reserved_prefixes.any? { |prefix| key.start_with?(prefix) }

    errors.add(:key, 'is reserved for system use')
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

  def system_field_identity_must_not_change
    return unless persisted_system_field?

    errors.add(:entity_kind, 'cannot be changed for system fields') if will_save_change_to_entity_kind?
    errors.add(:key, 'cannot be changed for system fields') if will_save_change_to_key?
    return unless will_save_change_to_field_type?

    errors.add(:field_type, 'cannot be changed for system fields')
  end

  def prevent_system_field_destroy
    return unless system?

    errors.add(:base, 'system field cannot be deleted')
    throw(:abort)
  end
end
