class AccessControl::ReleaseGate
  MUTATIONS_ENV = 'ACCESS_ROLE_MUTATIONS_ENABLED'.freeze
  ASSIGNMENTS_ENV = 'ACCESS_ROLE_ASSIGNMENTS_ENABLED'.freeze

  class InvalidConfiguration < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super("Invalid AccessRole release configuration: #{errors.join(', ')}")
    end
  end

  Configuration = Data.define(:mutations_enabled, :assignments_enabled, :errors) do
    def valid?
      errors.empty?
    end
  end

  Status = Data.define(
    :valid,
    :mutations_enabled,
    :assignments_enabled,
    :errors,
    :account_mode_counts,
    :canonical_role_count,
    :canonicalized_account_count
  )

  def self.configuration
    errors = []
    mutations_enabled = parse_flag(MUTATIONS_ENV, errors)
    assignments_enabled = parse_flag(ASSIGNMENTS_ENV, errors)
    errors << 'ACCESS_ROLE_ASSIGNMENTS_ENABLED requires ACCESS_ROLE_MUTATIONS_ENABLED=true' if assignments_enabled && !mutations_enabled

    Configuration.new(
      mutations_enabled: mutations_enabled,
      assignments_enabled: assignments_enabled,
      errors: errors.freeze
    )
  end

  def self.mutations_enabled?
    validated_configuration.mutations_enabled
  end

  def self.assignments_enabled?
    validated_configuration.assignments_enabled
  end

  def self.status
    config = configuration
    canonical_roles = AccessRole.canonical_grant_source

    Status.new(
      valid: config.valid?,
      mutations_enabled: config.mutations_enabled,
      assignments_enabled: config.assignments_enabled,
      errors: config.errors,
      account_mode_counts: Account.group(:access_control_mode).count.sort.to_h,
      canonical_role_count: canonical_roles.count,
      canonicalized_account_count: Account.where.not(access_role_canonicalized_at: nil)
                                          .or(Account.where(id: canonical_roles.select(:account_id)))
                                          .count
    )
  end

  def self.validated_configuration
    config = configuration
    raise InvalidConfiguration, config.errors unless config.valid?

    config
  end
  private_class_method :validated_configuration

  def self.parse_flag(name, errors)
    value = ENV.fetch(name, nil)
    return false if value.nil? || value == 'false'
    return true if value == 'true'

    errors << "#{name} must be exactly true or false"
    false
  end
  private_class_method :parse_flag
end
