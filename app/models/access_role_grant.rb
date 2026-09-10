class AccessRoleGrant < ApplicationRecord
  RESOURCE_CAPABILITIES = {
    'contacts' => %w[view create update_fields assign delete_archive view_configuration configure export view_reports],
    'conversations' => %w[view create update_fields assign transition take delete_archive view_configuration configure export view_reports],
    'appointments' => %w[
      view create update_fields assign transition delete_archive view_configuration configure export view_reports override_schedule
    ],
    'deals' => %w[view create update_fields assign transition delete_archive view_configuration configure export view_reports],
    'tasks' => %w[view create update_fields assign transition complete_cancel delete_archive view_configuration configure export view_reports]
  }.freeze
  RESOURCES = RESOURCE_CAPABILITIES.keys.freeze
  CAPABILITIES = RESOURCE_CAPABILITIES.values.flatten.uniq.freeze
  ACCESS_SCOPES = %w[none own team all].freeze

  belongs_to :account
  belongs_to :access_role, inverse_of: :grants

  audited associated_with: :account

  validates :resource, inclusion: { in: RESOURCES }
  validates :capability, inclusion: { in: CAPABILITIES }
  validates :access_scope, inclusion: { in: ACCESS_SCOPES }
  validates :capability, uniqueness: { scope: [:access_role_id, :resource] }
  validate :access_role_belongs_to_account
  validate :capability_supported_for_resource

  before_validation :normalize_attributes

  private

  def normalize_attributes
    self.resource = resource.to_s.strip
    self.capability = capability.to_s.strip
    self.access_scope = access_scope.to_s.strip
  end

  def access_role_belongs_to_account
    return if access_role.blank? || access_role.account_id == account_id

    errors.add(:access_role, 'must belong to the same account')
  end

  def capability_supported_for_resource
    return if RESOURCE_CAPABILITIES.fetch(resource, []).include?(capability)

    errors.add(:capability, 'is not supported for this resource')
  end
end
