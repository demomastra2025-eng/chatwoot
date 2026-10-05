# frozen_string_literal: true

# Collects the SQL statements a block runs, so specs can assert a query budget for a request or a service.
# Schema lookups, cached queries and transaction control statements are not counted.
module SqlQueryCounter
  TRANSACTION_SQL = /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE SAVEPOINT)\b/i

  def sql_queries_during(&)
    queries = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached] || payload[:name] == 'SCHEMA' || payload[:sql].to_s.match?(TRANSACTION_SQL)

      queries << payload[:sql].to_s.squish
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
    queries
  end
end

RSpec.configure do |config|
  config.include SqlQueryCounter
end
