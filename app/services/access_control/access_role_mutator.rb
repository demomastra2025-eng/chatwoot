class AccessControl::AccessRoleMutator
  class Error < StandardError
    attr_reader :code, :status

    def initialize(code, message, status: :unprocessable_content)
      @code = code
      @status = status
      super(message)
    end
  end

  def self.create(account:, attributes:)
    new(account).create(attributes)
  end

  def self.update(account:, access_role:, attributes:)
    new(account).update(access_role, attributes)
  end

  def self.destroy(account:, access_role:, lock_version:)
    new(account).destroy(access_role, lock_version)
  end

  def self.mutations_enabled_for?(account:)
    release_enabled? && account.access_control_mode_enforced?
  end

  def self.legacy_mutations_enabled_for?(account:)
    !mutations_enabled_for?(account: account) &&
      !account.access_roles.canonical_grant_source.exists?
  end

  def self.release_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('ACCESS_ROLE_MUTATIONS_ENABLED', false))
  end

  def initialize(account)
    @account = account
  end

  def create(attributes)
    ensure_release_enabled!

    account.with_lock do
      ensure_enforced!
      grants = extract_grants(attributes, required: true)
      custom_role = account.custom_roles.create!(
        name: attributes['name'],
        description: attributes['description'],
        permissions: []
      )
      role = account.access_roles.find_by!(legacy_custom_role_id: custom_role.id)
      ensure_exact_name!(role, custom_role)
      role.update!(grant_source: 'canonical')
      replace_grants(role, grants)
      role.reload
    end
  end

  def update(access_role, attributes)
    ensure_release_enabled!

    account.with_lock do
      ensure_enforced!
      role = lock_role(access_role)
      ensure_mutable!(role)
      ensure_current_version!(role, attributes['lock_version'])
      ensure_mutation_requested!(attributes)
      role.update!(grant_source: 'canonical') unless role.canonical_grant_source?
      update_legacy_metadata(role, attributes)
      replace_grants(role, extract_grants(attributes)) if attributes.key?('grants')
      role.reload
    end
  end

  def destroy(access_role, lock_version)
    ensure_release_enabled!

    account.with_lock do
      ensure_enforced!
      role = lock_role(access_role)
      ensure_mutable!(role)
      ensure_current_version!(role, lock_version)
      custom_role = role.legacy_custom_role
      destroyed = custom_role.destroy
      raise ActiveRecord::RecordInvalid, custom_role unless destroyed

      true
    end
  end

  private

  attr_reader :account

  def ensure_release_enabled!
    return if self.class.release_enabled?

    raise Error.new(
      'ACCESS_ROLE_MUTATIONS_NOT_ENABLED',
      'Normalized access role mutations are not enabled',
      status: :conflict
    )
  end

  def ensure_enforced!
    return if account.access_control_mode_enforced?

    raise Error.new('ACCESS_CONTROL_NOT_ENFORCED', 'Normalized role mutations require enforced access control', status: :conflict)
  end

  def lock_role(access_role)
    account.access_roles.lock.find(access_role.id)
  end

  def ensure_mutable!(role)
    raise Error.new('SYSTEM_ROLE_IMMUTABLE', 'System roles cannot be modified') if role.system_key?
    return if role.legacy_custom_role

    raise Error.new('LEGACY_IDENTITY_REQUIRED', 'Custom role is missing its legacy identity')
  end

  def ensure_current_version!(role, lock_version)
    raise Error.new('LOCK_VERSION_REQUIRED', 'lock_version is required') if lock_version.nil?

    expected_version = Integer(lock_version)
    return if role.lock_version == expected_version

    raise Error.new('STALE_ACCESS_ROLE', 'Access role has been changed by another request', status: :conflict)
  rescue ArgumentError, TypeError
    raise Error.new('INVALID_LOCK_VERSION', 'lock_version must be an integer')
  end

  def update_legacy_metadata(role, attributes)
    metadata = attributes.slice('name', 'description')
    return if metadata.empty?

    custom_role = role.legacy_custom_role
    custom_role.update!(metadata)
    role.reload
    ensure_exact_name!(role, custom_role)
  end

  def ensure_mutation_requested!(attributes)
    return if attributes.keys.intersect?(%w[name description grants])

    raise Error.new('MUTATION_REQUIRED', 'At least one role attribute or grants entry must be provided')
  end

  def ensure_exact_name!(role, custom_role)
    return if role.name == custom_role.name.to_s.strip

    custom_role.errors.add(:name, 'has already been taken')
    raise ActiveRecord::RecordInvalid, custom_role
  end

  def extract_grants(attributes, required: false)
    unless attributes.key?('grants')
      raise Error.new('GRANTS_REQUIRED', 'grants must be provided') if required

      return []
    end

    grants = Array(attributes['grants']).map do |grant|
      grant.symbolize_keys.slice(:resource, :capability, :access_scope)
    end
    keys = grants.map { |grant| [grant[:resource].to_s.strip, grant[:capability].to_s.strip] }
    return grants if keys.uniq.size == keys.size

    raise Error.new('DUPLICATE_GRANT', 'grants contain duplicate resource and capability entries')
  end

  def replace_grants(role, grants)
    AccessControl::LegacyCustomRoleMapper.reconcile_grants(role, grants)
    role.update!(updated_at: Time.current)
  end
end
