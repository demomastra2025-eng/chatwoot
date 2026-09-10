class AccessRole < ApplicationRecord
  SYSTEM_KEYS = %w[administrator department_lead employee commercial_director observer].freeze

  belongs_to :account
  belongs_to :legacy_custom_role, class_name: 'CustomRole', optional: true, inverse_of: :access_role

  has_many :grants,
           class_name: 'AccessRoleGrant',
           dependent: :destroy,
           inverse_of: :access_role
  has_many :account_users, dependent: :restrict_with_error
  has_many :account_user_lifecycle_snapshots, dependent: :restrict_with_error, inverse_of: :access_role

  audited associated_with: :account

  validates :name, presence: true, uniqueness: { scope: :account_id, case_sensitive: false }
  validates :system_key, inclusion: { in: SYSTEM_KEYS }, allow_nil: true
  validates :system_key, uniqueness: { scope: :account_id }, allow_nil: true
  validates :legacy_custom_role_id, uniqueness: true, allow_nil: true
  validate :legacy_custom_role_belongs_to_account
  validate :legacy_custom_role_is_not_system_role

  before_validation :normalize_attributes

  private

  def normalize_attributes
    self.name = name.to_s.strip
    self.description = description.to_s.strip.presence
    self.system_key = system_key.to_s.strip.presence
  end

  def legacy_custom_role_belongs_to_account
    return if legacy_custom_role.blank? || legacy_custom_role.account_id == account_id

    errors.add(:legacy_custom_role, 'must belong to the same account')
  end

  def legacy_custom_role_is_not_system_role
    return if legacy_custom_role.blank? || system_key.blank?

    errors.add(:legacy_custom_role, 'cannot be combined with a system role')
  end
end
