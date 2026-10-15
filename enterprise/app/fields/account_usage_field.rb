require 'administrate/field/base'

# The spend of a clinic (Account#account_usage_overview) as rows with a Russian name, the used / limit numbers and a
# meter; SuperAdmin::AccountUsage builds them, the partials draw them.
class AccountUsageField < Administrate::Field::Base
  def rows
    SuperAdmin::AccountUsage.new(overview: data.presence || {}).rows
  end
end
