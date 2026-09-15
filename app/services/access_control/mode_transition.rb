class AccessControl::ModeTransition
  TRANSITIONS = {
    'legacy' => %w[shadow],
    'shadow' => %w[legacy enforced],
    'enforced' => %w[shadow]
  }.freeze

  class InvalidTransition < StandardError; end

  class NotReady < StandardError
    attr_reader :readiness

    def initialize(readiness)
      @readiness = readiness
      super('Workspace is not ready for AccessRole enforcement')
    end
  end

  Result = Data.define(:account_id, :from, :to, :changed, :readiness)

  def self.call(account:, to:)
    new(account, to).call
  end

  def initialize(account, target_mode)
    @account = account
    @target_mode = target_mode.to_s
  end

  def call
    validate_target!
    result = account.with_lock do
      from = account.access_control_mode
      if from == target_mode
        Result.new(account_id: account.id, from: from, to: target_mode, changed: false, readiness: nil)
      else
        transition(from)
      end
    end
    Scheduling::ScopeInvalidation.dispatch(account) if result.changed
    result
  end

  private

  attr_reader :account, :target_mode

  def transition(from)
    validate_transition!(from)
    readiness = readiness_for_transition
    account.authorize_access_control_mode_transition do
      account.update!(access_control_mode: target_mode)
    end
    Result.new(account_id: account.id, from: from, to: target_mode, changed: true, readiness: readiness)
  end

  def validate_target!
    return if Account.access_control_modes.key?(target_mode)

    raise InvalidTransition, "Unsupported access control mode: #{target_mode}"
  end

  def validate_transition!(from)
    return if TRANSITIONS.fetch(from).include?(target_mode)

    raise InvalidTransition, "Access control mode cannot transition from #{from} to #{target_mode}"
  end

  def readiness_for_transition
    return unless target_mode == 'enforced'

    readiness = AccessControl::EnforcementReadiness.call(account: account)
    raise NotReady, readiness unless readiness.ready?

    readiness
  end
end
