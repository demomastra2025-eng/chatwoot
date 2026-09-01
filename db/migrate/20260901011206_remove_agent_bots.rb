class RemoveAgentBots < ActiveRecord::Migration[7.1]
  WRITE_GUARDS = {
    agent_bots: ['FALSE', 'agent_bots_retired'],
    agent_bot_inboxes: ['FALSE', 'agent_bot_inboxes_retired'],
    conversations: ['assignee_agent_bot_id IS NULL', 'conversations_agent_bot_assignment_retired'],
    messages: ["sender_type IS DISTINCT FROM 'AgentBot'", 'messages_agent_bot_sender_retired'],
    access_tokens: ["owner_type IS DISTINCT FROM 'AgentBot'", 'access_tokens_agent_bot_owner_retired'],
    active_storage_attachments: ["record_type IS DISTINCT FROM 'AgentBot'", 'attachments_agent_bot_record_retired'],
    platform_app_permissibles: ["permissible_type IS DISTINCT FROM 'AgentBot'", 'platform_permissions_agent_bot_retired']
  }.freeze
  REQUIRED_SCHEMA = {
    agent_bots: [],
    agent_bot_inboxes: [],
    conversations: [:assignee_agent_bot_id],
    messages: [:sender_type],
    access_tokens: [:owner_type],
    active_storage_attachments: [:record_type],
    platform_app_permissibles: [:permissible_type]
  }.freeze

  def up
    assert_required_schema!
    ensure_empty!(legacy_counts, 'compatibility rollout')

    install_write_guards
    ensure_empty!(legacy_counts, 'write-guard verification')
    say 'AgentBot schema removal is deferred to a contract release after the compatibility rollout'
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

    raise ActiveRecord::IrreversibleMigration, "AgentBot preflight schema missing: #{missing.join(', ')}"
  end

  def legacy_counts
    {
      agent_bots: count_rows(:agent_bots),
      agent_bot_inboxes: count_rows(:agent_bot_inboxes),
      conversations: count_where(:conversations, :assignee_agent_bot_id, 'assignee_agent_bot_id IS NOT NULL'),
      messages: count_where(:messages, :sender_type, "sender_type = 'AgentBot'"),
      access_tokens: count_where(:access_tokens, :owner_type, "owner_type = 'AgentBot'"),
      active_storage_attachments: count_where(:active_storage_attachments, :record_type, "record_type = 'AgentBot'"),
      platform_app_permissibles: count_where(:platform_app_permissibles, :permissible_type, "permissible_type = 'AgentBot'")
    }
  end

  def ensure_empty!(counts, phase)
    return unless counts.values.any?(&:positive?)

    details = counts.map { |name, count| "#{name}=#{count}" }.join(', ')
    raise ActiveRecord::IrreversibleMigration, "AgentBot #{phase} blocked: #{details}"
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
