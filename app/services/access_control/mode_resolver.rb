class AccessControl::ModeResolver
  Result = Data.define(:account_id, :mode, :authoritative_source, :access_role_resolution)

  def self.call(account_user:, resource:, capability:)
    new(account_user).call(resource: resource, capability: capability)
  end

  def self.mode_for_account(account_id)
    ActiveRecord::Base.uncached do
      Account.where(id: account_id).pick(:access_control_mode) || raise(ActiveRecord::RecordNotFound)
    end
  end

  def initialize(account_user)
    @account_user = account_user
  end

  def call(resource:, capability:)
    mode = access_control_mode
    resolution = resolve_access_role(resource, capability, mode)

    Result.new(
      account_id: account_user.account_id,
      mode: mode,
      authoritative_source: mode == 'enforced' ? 'access_role' : 'legacy',
      access_role_resolution: resolution
    )
  end

  private

  attr_reader :account_user

  def resolve_access_role(resource, capability, mode)
    return if mode == 'legacy'

    AccessControl::ShadowResolver.call(
      account_user: current_account_user,
      resource: resource,
      capability: capability
    )
  end

  def access_control_mode
    self.class.mode_for_account(account_user.account_id)
  end

  def current_account_user
    ActiveRecord::Base.uncached do
      AccountUser.includes(access_role: :grants).find_by!(id: account_user.id, account_id: account_user.account_id)
    end
  end
end
