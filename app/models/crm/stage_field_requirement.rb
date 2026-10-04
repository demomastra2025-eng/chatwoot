# == Schema Information
#
# Table name: crm_stage_field_requirements
#
class Crm::StageFieldRequirement < ApplicationRecord
  self.table_name = 'crm_stage_field_requirements'

  SUPPORTED_VALIDATIONS = %w[min_length max_length minimum maximum pattern].freeze
  SUPPORTED_ROLE_EXEMPTIONS = %w[agent administrator].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :stage, class_name: '::Crm::Stage', inverse_of: :field_requirements
  belongs_to :field_definition, class_name: '::Crm::FieldDefinition', optional: true

  validates :field_key, presence: true, uniqueness: { scope: :stage_id }
  validate :stage_belongs_to_account
  validate :field_key_is_supported
  validate :field_definition_matches_key
  validate :validation_keys_are_supported
  validate :role_exemptions_are_supported

  before_validation :sync_account
  before_validation :normalize_field_key
  before_validation :normalize_json_values

  private

  def sync_account
    self.account = stage.account if stage.present?
  end

  def normalize_field_key
    self.field_key = field_key.to_s.strip
  end

  def normalize_json_values
    self.validation = validation.to_h.stringify_keys
    self.role_exemptions = Array(role_exemptions).map(&:to_s).map(&:strip).reject(&:blank?).uniq
  end

  def stage_belongs_to_account
    return if stage.blank? || account.blank? || stage.account_id == account_id

    errors.add(:stage_id, 'must belong to the current account')
  end

  def field_key_is_supported
    return if field_key.blank?
    return if Crm::RequiredFieldsInspector::BUILT_IN_DEAL_FIELDS.key?(field_key)
    return if account&.crm_field_definitions&.exists?(entity_kind: 'deal', key: field_key)

    errors.add(:field_key, 'must reference a supported deal field')
  end

  def field_definition_matches_key
    return if field_definition.blank?
    return if field_definition.account_id == account_id && field_definition.entity_kind_deal? && field_definition.key == field_key

    errors.add(:field_definition_id, 'must match the account and field key')
  end

  def validation_keys_are_supported
    unsupported = validation.to_h.stringify_keys.keys - SUPPORTED_VALIDATIONS
    errors.add(:validation, "contains unsupported keys: #{unsupported.join(', ')}") if unsupported.any?
  end

  def role_exemptions_are_supported
    unsupported = Array(role_exemptions).map(&:to_s) - SUPPORTED_ROLE_EXEMPTIONS
    errors.add(:role_exemptions, "contains unsupported roles: #{unsupported.join(', ')}") if unsupported.any?
  end
end
