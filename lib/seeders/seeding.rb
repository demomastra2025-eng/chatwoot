# Whether demo data may be generated on this installation: the environment variable ENABLE_ACCOUNT_SEEDING, read as a
# boolean («false» and «0» are no), and when it is not set, only outside production. The button of the account card, the
# action behind it and the seeders themselves ask here, so a hidden button is not a way to a closed door.
module Seeders::Seeding
  module_function

  def enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('ENABLE_ACCOUNT_SEEDING', !Rails.env.production?)) == true
  end
end
