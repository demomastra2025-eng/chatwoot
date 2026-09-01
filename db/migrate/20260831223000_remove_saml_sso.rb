class RemoveSamlSso < ActiveRecord::Migration[7.1]
  WRITE_GUARDS = {
    account_saml_settings: ['FALSE', 'account_saml_settings_retired'],
    users: ["provider IS DISTINCT FROM 'saml'", 'users_saml_provider_retired']
  }.freeze
  REQUIRED_SCHEMA = {
    account_saml_settings: [],
    users: [:provider]
  }.freeze

  def up
    assert_required_schema!
    ensure_empty!(legacy_counts, 'compatibility rollout')

    install_write_guards
    ensure_empty!(legacy_counts, 'write-guard verification')
    say 'SAML schema removal is deferred to a contract release after the compatibility rollout'
  end

  def down
    remove_write_guards
  end

  private

  def assert_required_schema!
    missing = REQUIRED_SCHEMA.flat_map do |table, columns|
      next [table.to_s] unless table_exists?(table)

      columns.reject { |column| column_exists?(table, column) }.map { |column| "#{table}.#{column}" }
    end
    return if missing.empty?

    raise ActiveRecord::IrreversibleMigration, "SAML preflight schema missing: #{missing.join(', ')}"
  end

  def legacy_counts
    {
      users: count_where(:users, :provider, "provider = 'saml'"),
      account_settings: count_rows(:account_saml_settings)
    }
  end

  def ensure_empty!(counts, phase)
    return unless counts.values.any?(&:positive?)

    details = counts.map { |name, count| "#{name}=#{count}" }.join(', ')
    raise ActiveRecord::IrreversibleMigration, "SAML #{phase} blocked: #{details}"
  end

  def install_write_guards
    WRITE_GUARDS.each do |table, (expression, name)|
      next unless table_exists?(table)
      next if check_constraint_exists?(table, name: name)

      add_check_constraint(table, expression, name: name, validate: false)
    end
  end

  def remove_write_guards
    WRITE_GUARDS.each do |table, (_expression, name)|
      next unless table_exists?(table) && check_constraint_exists?(table, name: name)

      remove_check_constraint(table, name: name)
    end
  end

  def count_rows(table)
    return 0 unless table_exists?(table)

    select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i
  end

  def count_where(table, column, condition)
    return 0 unless table_exists?(table) && column_exists?(table, column)

    select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)} WHERE #{condition}").to_i
  end
end
