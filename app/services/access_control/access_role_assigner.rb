class AccessControl::AccessRoleAssigner
  class Error < StandardError
    attr_reader :code, :status

    def initialize(code, message, status: :unprocessable_content)
      @code = code
      @status = status
      super(message)
    end
  end

  EXPECTED_ROLE_UNSET = Object.new.freeze

  def self.assign(account:, account_user:, access_role_id:, expected_access_role_id: EXPECTED_ROLE_UNSET)
    new(account).assign(
      account_user: account_user,
      access_role_id: access_role_id,
      expected_access_role_id: expected_access_role_id
    )
  end

  def self.assignments_enabled_for?(account:)
    release_enabled? && account.access_control_mode_enforced?
  end

  def self.legacy_assignments_enabled_for?(account:)
    !assignments_enabled_for?(account: account)
  end

  def self.release_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('ACCESS_ROLE_ASSIGNMENTS_ENABLED', false))
  end

  def initialize(account)
    @account = account
  end

  def assign(account_user:, access_role_id:, expected_access_role_id: EXPECTED_ROLE_UNSET)
    account.with_lock do
      ensure_assignments_enabled!
      locked_account_user = account.account_users.lock.find(account_user.id)
      access_role = account.access_roles.find(access_role_id)
      ensure_current_assignment!(locked_account_user, access_role, expected_access_role_id)

      locked_account_user.__send__(:authorize_canonical_access_role_assignment) do
        locked_account_user.update!(legacy_attributes(access_role).merge(access_role: access_role))
      end
      locked_account_user
    end
  end

  private

  attr_reader :account

  def ensure_assignments_enabled!
    return if self.class.release_enabled? && account.access_control_mode_enforced?

    code = self.class.release_enabled? ? 'ACCESS_CONTROL_NOT_ENFORCED' : 'ACCESS_ROLE_ASSIGNMENTS_NOT_ENABLED'
    message = if self.class.release_enabled?
                'Normalized role assignments require enforced access control'
              else
                'Normalized role assignments are not enabled'
              end
    raise Error.new(code, message, status: :conflict)
  end

  def ensure_current_assignment!(account_user, access_role, expected_access_role_id)
    return if expected_access_role_id.equal?(EXPECTED_ROLE_UNSET)

    expected_id = normalize_expected_role_id(expected_access_role_id)
    return if account_user.access_role_id == expected_id
    return if account_user.access_role_id == access_role.id

    raise Error.new(
      'STALE_ACCESS_ROLE_ASSIGNMENT',
      'The employee role assignment has changed since it was loaded',
      status: :conflict
    )
  end

  def normalize_expected_role_id(value)
    return if value.nil?

    Integer(value)
  rescue ArgumentError, TypeError
    raise Error.new('INVALID_PREVIOUS_ACCESS_ROLE_ID', 'previous_access_role_id must be an integer or null')
  end

  def legacy_attributes(access_role)
    return { role: :administrator, custom_role: nil } if access_role.system_key == 'administrator'
    return { role: :agent, custom_role: nil } if access_role.system_key?
    return { role: :agent, custom_role: access_role.legacy_custom_role } if access_role.legacy_custom_role

    raise Error.new('LEGACY_IDENTITY_REQUIRED', 'Custom role is missing its legacy identity')
  end
end
