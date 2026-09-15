class Scheduling::ScopeInvalidation
  def self.dispatch(account)
    return if account.blank?

    Rails.configuration.dispatcher.dispatch(
      Events::Types::SCHEDULING_SCOPE_INVALIDATED,
      Time.zone.now,
      account: account
    )
  end
end
