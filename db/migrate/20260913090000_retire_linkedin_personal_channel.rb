class RetireLinkedinPersonalChannel < ActiveRecord::Migration[7.1]
  WRITE_GUARDS = {
    channel_linkedin_personal: %w[FALSE channel_linkedin_personal_retired],
    inboxes: ["channel_type IS DISTINCT FROM 'Channel::LinkedinPersonal'", 'inboxes_linkedin_personal_retired']
  }.freeze

  REQUIRED_SCHEMA = {
    channel_linkedin_personal: [],
    inboxes: [:channel_type]
  }.freeze

  def up
    assert_required_schema!
    ensure_empty!(legacy_counts, 'compatibility rollout')

    install_write_guards
    ensure_empty!(legacy_counts, 'write-guard verification')
    say 'LinkedIn Personal schema cleanup is deferred until every process runs the compatibility release'
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

    raise ActiveRecord::IrreversibleMigration, "LinkedIn Personal preflight schema missing: #{missing.join(', ')}"
  end

  def legacy_counts
    {
      channels: count_rows(:channel_linkedin_personal),
      inboxes: count_where(:inboxes, "channel_type = 'Channel::LinkedinPersonal'")
    }
  end

  def ensure_empty!(counts, phase)
    return unless counts.values.any?(&:positive?)

    details = counts.map { |name, count| "#{name}=#{count}" }.join(', ')
    raise ActiveRecord::IrreversibleMigration, "LinkedIn Personal #{phase} blocked: #{details}"
  end

  def install_write_guards
    WRITE_GUARDS.each do |table, (expression, name)|
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
    select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i
  end

  def count_where(table, condition)
    select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)} WHERE #{condition}").to_i
  end
end
