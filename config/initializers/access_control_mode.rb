Rails.application.config.to_prepare do
  Account.include(AccessControl::ModeControlled) unless Account < AccessControl::ModeControlled
end
