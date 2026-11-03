#!/usr/bin/env python3
"""Classify a Git range for OneLink CI and enforce migration release policy."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Iterable

RUBY_SUFFIXES = {".rb", ".rake"}
FRONTEND_SUFFIXES = {
    ".cjs",
    ".css",
    ".js",
    ".jsx",
    ".mjs",
    ".mts",
    ".scss",
    ".ts",
    ".tsx",
    ".vue",
}
RUBY_ROOTS = ("app/", "config/", "db/", "enterprise/", "lib/", "spec/")
FRONTEND_ROOTS = ("app/javascript/", "enterprise/app/javascript/", "test/", "tests/")
CONTAINER_FILES = {
    "Dockerfile",
    "Gemfile",
    "Gemfile.lock",
    "package.json",
    "pnpm-lock.yaml",
    "docker/Dockerfile",
    ".dockerignore",
}
HIGH_RISK_ROOTS = (
    ".github/workflows/",
    "config/initializers/",
    "config/routes",
    "db/migrate/",
    "deploy/",
    "docker/",
    "enterprise/app/policies/",
    "app/policies/",
    "app/jobs/",
    "app/services/whatsapp/",
    "app/services/telegram/",
    "app/services/telephony/",
    "services/onelink-ai-voice/",
    "services/onelink-ai-voice-pipecat/",
)
SIDECAR_ROOTS = (
    "enterprise/media-server/",
    "services/onelink-ai-voice/",
    "services/onelink-ai-voice-pipecat/",
)
IMMUTABLE_RELEASE_SIDECAR_ROOTS = ("services/onelink-ai-voice/",)
# Captain control is enforced through model callbacks, so its regression specs
# (including the legacy-column rollout bridge) live with the models.
CAPTAIN_CONTROL_SPECS = (
    "spec/models/conversation_spec.rb",
    "spec/enterprise/models/message_spec.rb",
)
# The Captain takeover callback runs before every public reply in every inbox,
# so its changes also run the reply paths that rely on the caller's cached
# conversation inbox, channel and communication thread.
MESSAGE_CALLBACK_SPECS = CAPTAIN_CONTROL_SPECS + (
    "spec/listeners/action_cable_listener_spec.rb",
    "spec/listeners/whatsapp_typing_listener_spec.rb",
    "spec/services/messages/update_content_service_spec.rb",
    "spec/services/whatsapp_web/send_on_whatsapp_web_service_spec.rb",
)
COMPANION_SPECS = {
    "enterprise/app/services/captain/conversation/": CAPTAIN_CONTROL_SPECS,
    "enterprise/app/models/enterprise/conversation.rb": CAPTAIN_CONTROL_SPECS,
    "enterprise/app/models/enterprise/message.rb": MESSAGE_CALLBACK_SPECS,
}
DESTRUCTIVE_MIGRATION_PATTERN = re.compile(
    r"\b(remove_column|remove_columns|drop_table|rename_column|change_column|"
    r"change_column_null|change_column_default|remove_index|remove_foreign_key|rename_table)\b"
)
# This one guarded SET DEFAULT only repairs a missing UUID generator on an
# existing CRM table. Keep the exception bound to this migration and its exact
# nil checks; unmatched default changes remain destructive.
SAFE_STAGE_VISIT_UUID_DEFAULT_MIGRATION = "db/migrate/20261004120100_create_crm_lifecycle_tables.rb"
SAFE_STAGE_VISIT_UUID_DEFAULT_BLOCK = re.compile(
    r"""
    correlation_id_column\s*=\s*connection\.columns\(\s*:crm_stage_visits\s*\)\.find\s+do\s*\|\s*column\s*\|\s*
        column\.name\s*==\s*'correlation_id'\s*
    end\s*
    raise\s+'crm_stage_visits\.correlation_id\s+is\s+missing'\s+unless\s+correlation_id_column\s*
    actual_uuid_defaults\s*=\s*\[\s*
        correlation_id_column\.default\s*,\s*correlation_id_column\.default_function\s*
    \]\s*
    has_expected_uuid_default\s*=\s*actual_uuid_defaults\.include\?\(\s*'gen_random_uuid\(\)'\s*\)\s*
    has_no_uuid_default\s*=\s*actual_uuid_defaults\.all\?\(\s*&:nil\?\s*\)\s*
    if\s+has_no_uuid_default\s*
    change_column_default\s*\(\s*:crm_stage_visits\s*,\s*:correlation_id\s*,
        \s*->\s*\{\s*'gen_random_uuid\(\)'\s*\}\s*\)\s*
    elsif\s+!has_expected_uuid_default\s*
    raise\s+["']Unexpected\s+crm_stage_visits\.correlation_id\s+default:\s*
        \#\{actual_uuid_defaults\.inspect\}["']\s*
    end
    """,
    re.DOTALL | re.VERBOSE,
)
# These two unpublished expand migrations need a nullable history reference and
# a verified concurrent index swap. Accept only their exact protected blocks;
# other nullability changes and index removals still fail the release gate.
SAFE_SCENARIO_HISTORY_MIGRATION = "db/migrate/20261011080000_create_captain_standalone_agents.rb"
SAFE_CRM_TARGET_INDEX_MIGRATION = "db/migrate/20261011093000_update_crm_appointment_target_indexes.rb"
SAFE_SHORT_LOCK_SETTINGS = """  disable_ddl_transaction!

  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5
"""
SAFE_SHORT_LOCK_BLOCK = """  def with_short_lock_timeout
    attempt = 0
    begin
      attempt += 1
      transaction(requires_new: true) do
        execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")
        yield
      end
    rescue ActiveRecord::LockWaitTimeout
      raise if attempt >= LOCK_ATTEMPTS

      sleep(attempt)
      retry
    end
  end"""
SAFE_SCENARIO_HISTORY_BLOCK = """  def preserve_legacy_scenario_history
    with_short_lock_timeout do
      change_column_null(:captain_scenarios, :assistant_id, true)
    end
  end"""
SAFE_CRM_TARGET_INDEX_SWAP_BLOCK = """  def remove_replaced_index(name, replacement, source_key)
    definition = index_definition(name)
    return unless definition

    raise ActiveRecord::MigrationError, "Unexpected index definition for #{name}" unless known_target_index?(definition, source_key)
    raise ActiveRecord::MigrationError, "Valid replacement missing for #{name}" unless fixed_valid_index?(replacement, source_key)

    remove_index :crm_pipelines, name: name, algorithm: :concurrently
  end"""
SAFE_CRM_TARGET_INDEX_GUARDS = (
    """  INDEXES = {
    'idx_crm_pipeline_calendar_target' => 'auto_create_from_calendar',
    'idx_crm_pipeline_medelement_target' => 'auto_create_from_medelement'
  }.freeze""",
    """  def known_target_index?(definition, source_key)
    target_index_shape?(definition) && [legacy_predicate(source_key), predicate(source_key)].any? do |expected|
      normalize_predicate(definition['predicate']) == normalize_predicate(expected)
    end
  end""",
    """  def target_index_shape?(definition)
    definition['indisunique'] && definition['account_id_only']
  end""",
    """  def legacy_predicate(source_key)
    "active AND appointment_automation ->> '#{source_key}' = 'true'"
  end""",
    """  def predicate(source_key)
    "active AND appointment_automation ->> '#{source_key}' = 'true' " \\
      "AND (appointment_automation ->> 'auto_create_deals') IS DISTINCT FROM 'false'"
  end""",
    """  def fixed_valid_index?(name, source_key)
    definition = index_definition(name)
    return false unless definition && definition['indisvalid'] && target_index_shape?(definition)

    normalize_predicate(definition['predicate']) == normalize_predicate(predicate(source_key))
  end""",
    """  def normalize_predicate(value)
    value.to_s.gsub(/::text|[\\s()]/, '')
  end""",
    """  def index_definition(name)
    select_one <<~SQL.squish
      SELECT indisvalid, indisunique, pg_get_expr(indpred, indrelid) AS predicate,
             indnkeyatts = 1 AND indnatts = 1 AND indkey[0] = (
               SELECT attnum FROM pg_attribute WHERE attrelid = indrelid AND attname = 'account_id'
             ) AS account_id_only
      FROM pg_index
      WHERE indexrelid = to_regclass(#{quote(name)})
        AND indrelid = to_regclass('crm_pipelines')
    SQL
  end""",
)
# The six unpublished migrations have a reviewed invocation/lock contract.
# These are operation-level safety closures, not file fingerprints: only the
# specifically listed DDL below is exempted, and the rest is still scanned.
# Changing a guard, its transitive compatibility checks, or invocation requires
# renewed review. New unsafe statements beside a protected block remain errors.
AI_EXPAND_GUARDS = {
    'db/migrate/20261102013000_create_account_ai_usage_events.rb': (
        r'''  def up
    execute "SET LOCAL lock_timeout = '4s'"
    execute "SET LOCAL statement_timeout = '5s'"
    create_dialog_states
    create_usage_events
    create_rollout
    add_validated_foreign_keys
    add_message_columns
  end''',
        r'''  def add_validated_foreign_keys
    add_foreign_key :account_ai_dialog_states, :accounts, column: :account_id, on_delete: :cascade, validate: false
    validate_foreign_key :account_ai_dialog_states, :accounts, column: :account_id
    add_foreign_key :account_ai_dialog_states, :contacts, column: :contact_id, on_delete: :cascade, validate: false
    validate_foreign_key :account_ai_dialog_states, :contacts, column: :contact_id
    add_foreign_key :account_ai_usage_events, :contacts, column: :contact_id, on_delete: :nullify, validate: false
    validate_foreign_key :account_ai_usage_events, :contacts, column: :contact_id
    add_foreign_key :account_ai_usage_events, :accounts, column: :account_id, on_delete: :cascade, validate: false
    validate_foreign_key :account_ai_usage_events, :accounts, column: :account_id
  end''',
    ),
    'db/migrate/20261102013100_add_pending_ai_usage_index_to_messages.rb': (
        '  disable_ddl_transaction!',
        r'''  def up
    previous_lock_timeout = select_value('SHOW lock_timeout')
    execute "SET lock_timeout = '4s'"
    repair_known_invalid_index
    add_index :messages, [:ai_usage_retry_at, :id], where: 'ai_usage_pending = true', name: 'idx_messages_pending_ai_usage', algorithm: :concurrently,
                                                    if_not_exists: true
    definition = pending_index_definition
    unless known_pending_index?(definition) && definition['indisvalid'] && definition['indisready'] && definition['indislive']
      raise ActiveRecord::MigrationError, 'pending AI usage index is not ready and valid'
    end
  ensure
    execute "SET lock_timeout = #{connection.quote(previous_lock_timeout)}" if previous_lock_timeout
  end''',
        r'''  def repair_known_invalid_index
    return unless select_value("SELECT to_regclass(quote_ident(current_schema()) || '.idx_messages_pending_ai_usage')")

    definition = pending_index_definition
    raise ActiveRecord::MigrationError, 'unknown pending AI usage index shape: explicit maintenance required' unless known_pending_index?(definition)

    remove_index :messages, name: 'idx_messages_pending_ai_usage', algorithm: :concurrently unless definition['indisvalid']
  end''',
        r'''  def known_pending_index?(definition)
    definition && definition['known_shape'] && definition['predicate'].to_s.gsub(/[\s()]/, '') == 'ai_usage_pending=true'
  end''',
        r'''  def pending_index_definition
    select_one <<~SQL.squish
      SELECT idx.indisvalid, idx.indisready, idx.indislive, pg_get_expr(idx.indpred, idx.indrelid) AS predicate,
        am.amname = 'btree' AND NOT idx.indisunique AND NOT idx.indisexclusion
        AND idx.indnkeyatts = 2 AND idx.indnatts = 2 AND idx.indexprs IS NULL
        AND idx.indoption::text = '0 0' AND idx.indcollation::text = '0 0'
        AND NOT EXISTS (SELECT 1 FROM unnest(idx.indclass) AS opclass(oid)
          JOIN pg_opclass opc ON opc.oid = opclass.oid WHERE NOT opc.opcdefault)
        AND ARRAY(SELECT attr.attname::text FROM unnest(idx.indkey) WITH ORDINALITY AS key(attnum, position)
          JOIN pg_attribute attr ON attr.attrelid = idx.indrelid AND attr.attnum = key.attnum ORDER BY key.position)
          = ARRAY['ai_usage_retry_at', 'id']::text[] AS known_shape
      FROM pg_index idx JOIN pg_class index_relation ON index_relation.oid = idx.indexrelid
      JOIN pg_am am ON am.oid = index_relation.relam
      WHERE idx.indexrelid = to_regclass(quote_ident(current_schema()) || '.idx_messages_pending_ai_usage')
        AND idx.indrelid = to_regclass(quote_ident(current_schema()) || '.messages')
    SQL
  end''',
    ),
    'db/migrate/20261102013200_create_captain_reply_suggestion_identities.rb': (
        r'''  def up
    execute "SET LOCAL lock_timeout = '4s'"
    execute "SET LOCAL statement_timeout = '5s'"
    create_table :captain_reply_suggestion_identities do |t|
      t.string :request_id, null: false
      t.references :account, null: false, index: false
      t.references :conversation, null: false, index: false
      t.references :user, null: false, index: false
      t.datetime :generated_at, null: false
      t.timestamps
    end
    add_index :captain_reply_suggestion_identities, :request_id, unique: true, name: 'idx_reply_suggestion_identity_request'
    add_index :captain_reply_suggestion_identities, :conversation_id, name: 'idx_reply_suggestion_identity_conversation'
    add_validated_foreign_keys
  end''',
        r'''  def add_validated_foreign_keys
    add_foreign_key :captain_reply_suggestion_identities, :accounts, column: :account_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_reply_suggestion_identities, :accounts, column: :account_id
    add_foreign_key :captain_reply_suggestion_identities, :conversations, column: :conversation_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_reply_suggestion_identities, :conversations, column: :conversation_id
    add_foreign_key :captain_reply_suggestion_identities, :users, column: :user_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_reply_suggestion_identities, :users, column: :user_id
  end''',
    ),
    'db/migrate/20261102093000_manage_organization_billing_foundation.rb': (
        r'''  TABLES = %i[billing_accounts billing_account_workspaces billing_subscriptions].freeze
  ENTITLING = "status IN ('trialing', 'active', 'past_due', 'grace_period')"
  ACCOUNT_STATUS = "status::text = ANY (ARRAY['active'::text,'past_due'::text,'suspended'::text,'closed'::text])"
  SUBSCRIPTION_STATUS = "status::text = ANY (ARRAY['incomplete'::text,'trialing'::text,'active'::text,'past_due'::text," \
                        "'grace_period'::text,'suspended'::text,'canceled'::text])"
  WORKSPACE_STATUS = "status::text = ANY (ARRAY['active'::text,'detached'::text])"
  DETACHED = "status::text = 'active'::text AND detached_at IS NULL OR status::text = 'detached'::text AND detached_at IS NOT NULL"
  PERIOD = 'current_period_starts_at IS NULL OR current_period_ends_at IS NULL OR current_period_ends_at > current_period_starts_at'
'''.rstrip('\n'),
        r'''  def up
    execute "SET LOCAL lock_timeout = '4s'"
    execute "SET LOCAL statement_timeout = '5s'"
    present = TABLES.select { |table| local_table?(table) }
    raise ActiveRecord::MigrationError, 'partial billing foundation: explicit structural repair required' if present.any? && present != TABLES

    if present.empty?
      create_foundation
    else
      lock_bounded_legacy_foundation!
      validate_legacy_foundation!
    end
    add_ownership
    add_history
    add_subscription_contract
  end''',
        r'''  def local_table?(table)
    connection.select_value("SELECT to_regclass(quote_ident(current_schema()) || '.' || #{connection.quote(table.to_s)})").present?
  end''',
        r'''  def lock_bounded_legacy_foundation!
    validate_legacy_relations!
    execute 'LOCK TABLE billing_accounts, billing_account_workspaces, billing_subscriptions IN ACCESS EXCLUSIVE MODE'
    validate_legacy_relations!
    TABLES.each do |table|
      size = select_value("SELECT pg_total_relation_size(to_regclass(#{relation_literal(table)}))").to_i
      rows = select_value("SELECT count(*) FROM (SELECT 1 FROM ONLY #{connection.quote_table_name(table)} LIMIT 513) bounded_rows").to_i
      next if size <= 1_048_576 && rows <= 512

      raise ActiveRecord::MigrationError, "billing foundation exceeds tiny limits: explicit maintenance required (#{table})"
    end
  end''',
        r'''  def validate_legacy_relations!
    TABLES.each do |table|
      ordinary = select_value(<<~SQL.squish)
        SELECT relkind = 'r' AND relpersistence = 'p' AND NOT relispartition
          AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = relation.oid OR inhparent = relation.oid)
        FROM pg_class relation WHERE oid = to_regclass(#{relation_literal(table)})
      SQL
      raise ActiveRecord::MigrationError, "non-ordinary billing foundation: explicit maintenance required (#{table})" unless ordinary
    end
  end''',
        r'''  def validate_legacy_foundation!
    TABLES.each { |table| validate_columns!(table) }
    validate_checks!(:billing_accounts, 'chk_billing_accounts_status' => ACCOUNT_STATUS,
                                        'chk_billing_accounts_currency' => "default_currency::text ~ '^[A-Z]{3}$'::text")
    validate_checks!(:billing_account_workspaces, 'chk_billing_workspaces_status' => WORKSPACE_STATUS,
                                                  'chk_billing_workspaces_detached_at' => DETACHED)
    validate_checks!(:billing_subscriptions, 'chk_billing_subscriptions_status' => SUBSCRIPTION_STATUS,
                                             'chk_billing_subscriptions_period' => PERIOD)
    validate_indexes_and_keys!
  end''',
        r'''  def validate_columns!(table)
    required = required_columns.fetch(table).merge('id' => ['bigint', false], 'created_at' => ['timestamp(6) without time zone', false],
                                                   'updated_at' => ['timestamp(6) without time zone', false])
    columns = connection.columns(table).index_by(&:name)
    raise ActiveRecord::MigrationError, "unexpected columns in #{table}" if (columns.keys - required.keys).any?

    required.each do |name, (type, nullable)|
      column = columns[name]
      next if column && column.sql_type == type && column.null == nullable

      raise ActiveRecord::MigrationError, "incompatible #{table}.#{name}: expected #{type}, nullable=#{nullable}"
    end
    validate_defaults!(table, columns)
    validate_primary_key!(table)
  end''',
        r'''  def validate_defaults!(table, columns)
    common = { 'metadata' => '{}' }
    expected = {
      billing_accounts: common.merge('status' => 'active', 'default_currency' => 'KZT', 'default_locale' => 'ru'),
      billing_account_workspaces: common.merge('status' => 'active'),
      billing_subscriptions: common.merge('status' => 'incomplete', 'cancel_at_period_end' => 'false',
                                          'plan_snapshot' => '{}', 'price_snapshot' => '{}')
    }.fetch(table)
    expressions = default_expressions(table)
    columns.except('id').each do |name, column|
      next if expressions[name] == literal_default_expression(column, expected[name])

      raise ActiveRecord::MigrationError, "incompatible default #{table}.#{name}"
    end
  end''',
        r'''  def default_expressions(table)
    connection.select_rows(<<~SQL.squish).to_h
      SELECT attr.attname, pg_get_expr(def.adbin, def.adrelid)
      FROM pg_attribute attr LEFT JOIN pg_attrdef def ON def.adrelid = attr.attrelid AND def.adnum = attr.attnum
      WHERE attr.attrelid = to_regclass(#{relation_literal(table)}) AND attr.attnum > 0 AND NOT attr.attisdropped
    SQL
  end''',
        r'''  def literal_default_expression(column, value)
    return if value.nil?
    return value if column.type == :boolean

    type = column.type == :jsonb ? 'jsonb' : 'character varying'
    "#{connection.quote(value)}::#{type}"
  end''',
        r'''  def relation_literal(table)
    connection.quote("#{connection.quote_table_name(connection.current_schema)}.#{connection.quote_table_name(table)}")
  end''',
        r'''  def validate_primary_key!(table)
    valid = connection.select_value(<<~SQL.squish)
      SELECT idx.indisvalid AND idx.indisready AND idx.indislive AND idx.indisunique AND idx.indimmediate
        AND idx.indnkeyatts = 1 AND idx.indnatts = 1 AND attr.attname = 'id'
        AND con.convalidated AND NOT con.condeferrable
      FROM pg_index idx
      JOIN pg_constraint con ON con.conindid = idx.indexrelid AND con.contype = 'p'
      JOIN pg_attribute attr ON attr.attrelid = idx.indrelid AND attr.attnum = idx.indkey[0]
      WHERE idx.indrelid = to_regclass(#{relation_literal(table)}) AND idx.indisprimary
    SQL
    raise ActiveRecord::MigrationError, "incompatible primary key #{table}: expected valid id PK" unless valid

    validate_id_generator!(table)
  end''',
        r'''  def validate_id_generator!(table)
    generator = connection.select_one(<<~SQL.squish)
      SELECT attr.attidentity AS identity_kind, pg_get_expr(def.adbin, def.adrelid) AS expression,
        seq.seqincrement > 0 AND NOT seq.seqcycle AS sequence_ok,
        EXISTS (SELECT 1 FROM pg_depend dep WHERE dep.classid = 'pg_attrdef'::regclass
          AND dep.objid = def.oid AND dep.refclassid = 'pg_class'::regclass AND dep.refobjid = seq.seqrelid) AS default_uses_owned_sequence
      FROM pg_attribute attr
      LEFT JOIN pg_attrdef def ON def.adrelid = attr.attrelid AND def.adnum = attr.attnum
      LEFT JOIN pg_sequence seq ON seq.seqrelid = pg_get_serial_sequence(#{relation_literal(table)}, 'id')::regclass
      WHERE attr.attrelid = to_regclass(#{relation_literal(table)}) AND attr.attname = 'id'
    SQL
    direct_serial = generator['expression'].to_s.match?(/\Anextval\('(?:[^']|'')+'::regclass\)\z/) && generator['default_uses_owned_sequence']
    valid = generator['sequence_ok'] && (%w[a d].include?(generator['identity_kind']) || direct_serial)
    raise ActiveRecord::MigrationError, "incompatible id generation #{table}.id" unless valid
  end''',
        r'''  def required_columns
    common = { 'status' => ['character varying', false], 'metadata' => ['jsonb', false] }
    {
      billing_accounts: common.merge('name' => ['character varying', false], 'default_currency' => ['character varying(3)', false],
                                     'default_locale' => ['character varying', false]),
      billing_account_workspaces: common.merge('billing_account_id' => ['bigint', false], 'account_id' => ['integer', false],
                                               'detached_at' => ['timestamp(6) without time zone', true]),
      billing_subscriptions: common.merge('billing_account_id' => ['bigint', false], 'billing_plan_id' => ['bigint', false],
                                          'billing_plan_price_id' => ['bigint', true], 'plan_snapshot' => ['jsonb', false],
                                          'price_snapshot' => ['jsonb', false], 'cancel_at_period_end' => ['boolean', false],
                                          'provider' => ['character varying', true], 'external_id' => ['character varying', true],
                                          'current_period_starts_at' => ['timestamp(6) without time zone', true],
                                          'current_period_ends_at' => ['timestamp(6) without time zone', true])
    }
  end''',
        r'''  def normalized_sql(value)
    value.to_s.gsub(/::(?:character varying|text)(?:\[\])?/, '').gsub(/[\s()]/, '')
  end''',
        r'''  def validate_checks!(table, expected)
    actual = connection.check_constraints(table).index_by(&:name)
    expected.each do |name, expression|
      constraint = actual[name]
      next if constraint&.validated? && normalized_sql(constraint.expression) == normalized_sql(expression)

      raise ActiveRecord::MigrationError, "incompatible constraint #{table}.#{name}"
    end
  end''',
        r'''  def validate_index!(table, name, columns, predicate)
    index = connection.indexes(table).find { |value| value.name == name }
    return if index&.unique && index.columns == columns && normalized_sql(index.where) == normalized_sql(predicate) && valid_unique_index?(table,
                                                                                                                                           name)

    raise ActiveRecord::MigrationError, "incompatible unique index #{table}.#{name}"
  end''',
        r'''  def valid_unique_index?(table, name)
    connection.select_value(<<~SQL.squish)
      SELECT indisvalid AND indisready AND indislive AND indisunique AND indimmediate
      FROM pg_index WHERE indrelid = to_regclass(#{relation_literal(table)}) AND indexrelid = to_regclass(#{relation_literal(name)})
    SQL
  end''',
        r'''  def validate_indexes_and_keys!
    validate_index!(:billing_account_workspaces, 'idx_billing_workspaces_one_active_account', ['account_id'], "status = 'active'")
    validate_index!(:billing_subscriptions, 'idx_billing_subscriptions_one_entitling', ['billing_account_id'],
                    "status::text = ANY (ARRAY['trialing'::text,'active'::text,'past_due'::text,'grace_period'::text])")
    validate_index!(:billing_subscriptions, 'idx_billing_subscriptions_provider_external', %w[provider external_id], 'external_id IS NOT NULL')
    { billing_account_workspaces: { billing_accounts: 'billing_account_id', accounts: 'account_id' },
      billing_subscriptions: { billing_accounts: 'billing_account_id', billing_plans: 'billing_plan_id',
                               billing_plan_prices: 'billing_plan_price_id' } }.each do |table, keys|
      keys.each do |target, column|
        validate_foreign_key!(table, target, column)
      end
    end
  end''',
        r'''  def validate_foreign_key!(table, target, column)
    key = connection.foreign_keys(table).find { |fk| [fk.to_table, fk.column] == [target.to_s, column] }
    allowed_delete = [table, target] == [:billing_account_workspaces, :accounts] ? [nil, :cascade] : [nil]
    return if key&.validated? && key.primary_key == 'id' && allowed_delete.include?(key.on_delete)

    raise ActiveRecord::MigrationError, "missing validated FK #{table}.#{column} or incompatible deletion rule"
  end''',
        r'''  def add_state(table)
    add_column table, :foundation_state, :string, null: false, default: 'legacy_pending'
    change_column_default table, :foundation_state, from: 'legacy_pending', to: 'ready'
    add_check_constraint table, "foundation_state IN ('ready', 'legacy_pending')", name: "chk_#{table}_foundation_state", validate: false
    validate_check_constraint table, name: "chk_#{table}_foundation_state"
  end''',
        r'''  def add_ownership
    add_state(:billing_accounts)
    add_reference :billing_accounts, :organization
    add_reference :billing_accounts, :standalone_account
    add_foreign_key :billing_accounts, :organizations, validate: false
    validate_foreign_key :billing_accounts, :organizations
    add_foreign_key :billing_accounts, :accounts, column: :standalone_account_id, validate: false
    validate_foreign_key :billing_accounts, :accounts, column: :standalone_account_id
    owner_check = "foundation_state = 'legacy_pending' OR " \
                  "((organization_id IS NULL) <> (standalone_account_id IS NULL) AND default_currency = 'KZT')"
    add_check_constraint :billing_accounts, owner_check, name: 'chk_billing_accounts_explicit_owner', validate: false
    validate_check_constraint :billing_accounts, name: 'chk_billing_accounts_explicit_owner'
    add_index :billing_accounts, :organization_id, unique: true, where: "foundation_state = 'ready'", name: 'idx_billing_accounts_org_owner'
    add_index :billing_accounts, :standalone_account_id, unique: true, where: "foundation_state = 'ready'",
                                                         name: 'idx_billing_accounts_standalone_owner'
  end''',
        r'''  def add_history
    add_state(:billing_account_workspaces)
    add_column :billing_account_workspaces, :starts_at, :datetime
    add_check_constraint :billing_account_workspaces,
                         "foundation_state = 'legacy_pending' OR (starts_at IS NOT NULL AND (detached_at IS NULL OR detached_at > starts_at))",
                         name: 'chk_billing_workspaces_known_interval', validate: false
    validate_check_constraint :billing_account_workspaces, name: 'chk_billing_workspaces_known_interval'
    key = connection.foreign_keys(:billing_account_workspaces).find { |fk| fk.to_table == 'accounts' && fk.column == 'account_id' }
    remove_foreign_key :billing_account_workspaces, name: key.name
    add_foreign_key :billing_account_workspaces, :accounts, validate: false
    validate_foreign_key :billing_account_workspaces, :accounts
    enable_extension 'btree_gist' unless extension_enabled?('btree_gist')
    add_exclusion_constraint :billing_account_workspaces,
                             "account_id WITH =, tsrange(starts_at, detached_at, '[)') WITH &&",
                             using: :gist, where: "foundation_state = 'ready'", name: 'excl_billing_workspace_intervals'
  end''',
        r'''  def add_subscription_contract
    add_state(:billing_subscriptions)
    change_column_null :billing_subscriptions, :billing_plan_id, true
    add_check_constraint :billing_subscriptions, <<~SQL.squish, name: 'chk_billing_subscriptions_snapshot_contract', validate: false
      foundation_state = 'legacy_pending' OR (
        billing_plan_id IS NULL AND billing_plan_price_id IS NULL
        AND jsonb_typeof(plan_snapshot) = 'object' AND jsonb_typeof(price_snapshot) = 'object'
        AND plan_snapshot @> '{"schema_version":1,"source":"account_plans"}'::jsonb
        AND price_snapshot @> '{"schema_version":1,"source":"account_plans","currency":"KZT"}'::jsonb
        AND plan_snapshot ?& ARRAY['catalog_version','tariff','modules','features','limits','limit_sources']
        AND price_snapshot ?& ARRAY['catalog_version','tariff','pricing']
        AND plan_snapshot->'catalog_version' = price_snapshot->'catalog_version'
        AND plan_snapshot->'tariff' = price_snapshot->'tariff'
        AND jsonb_typeof(plan_snapshot->'limits') = 'object'
        AND jsonb_typeof(plan_snapshot->'limit_sources') = 'object'
        AND jsonb_typeof(price_snapshot->'pricing') = 'object'
      )
    SQL
    validate_check_constraint :billing_subscriptions, name: 'chk_billing_subscriptions_snapshot_contract'
  end''',
    ),
    'db/migrate/20261102103000_create_billing_unit_ledger.rb': (
        r'''  def up
    execute "SET LOCAL lock_timeout = '4s'"
    execute "SET LOCAL statement_timeout = '5s'"
    raise ActiveRecord::MigrationError, 'unit ledger tables already exist: review their origin' if TABLES.any? { |table| local_table?(table) }

    create_periods
    create_projections
    create_revisions
    add_validated_foreign_keys
  end''',
        r'''  def add_validated_foreign_keys
    add_foreign_key :billing_usage_periods, :billing_accounts, column: :billing_account_id, validate: false
    validate_foreign_key :billing_usage_periods, :billing_accounts, column: :billing_account_id
    add_foreign_key :billing_usage_periods, :billing_subscriptions, column: :billing_subscription_id, validate: false
    validate_foreign_key :billing_usage_periods, :billing_subscriptions, column: :billing_subscription_id
    add_foreign_key :billing_usage_projections, :accounts, column: :account_id, validate: false
    validate_foreign_key :billing_usage_projections, :accounts, column: :account_id
    add_foreign_key :billing_usage_projections, :billing_usage_projections, column: :retired_into_id, validate: false
    validate_foreign_key :billing_usage_projections, :billing_usage_projections, column: :retired_into_id
    add_foreign_key :billing_usage_revisions, :billing_usage_periods, column: :billing_usage_period_id, validate: false
    validate_foreign_key :billing_usage_revisions, :billing_usage_periods, column: :billing_usage_period_id
    add_foreign_key :billing_usage_revisions, :billing_usage_projections, column: :billing_usage_projection_id, validate: false
    validate_foreign_key :billing_usage_revisions, :billing_usage_projections, column: :billing_usage_projection_id
  end''',
    ),
    'db/migrate/20261103010000_create_captain_shadow_training.rb': (
        r'''  def up
    execute "SET LOCAL lock_timeout = '4s'"
    execute "SET LOCAL statement_timeout = '5s'"
    create_runs
    create_candidates
    add_validated_foreign_keys
  end''',
        r'''  def add_validated_foreign_keys
    add_foreign_key :captain_shadow_training_runs, :accounts, column: :account_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :accounts, column: :account_id
    add_foreign_key :captain_shadow_training_runs, :conversations, column: :conversation_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :conversations, column: :conversation_id
    add_foreign_key :captain_shadow_training_runs, :captain_assistants, column: :assistant_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :captain_assistants, column: :assistant_id
    add_foreign_key :captain_shadow_training_runs, :users, column: :user_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :users, column: :user_id
    add_foreign_key :captain_shadow_training_runs, :messages, column: :inbound_message_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :messages, column: :inbound_message_id
    add_foreign_key :captain_shadow_training_runs, :messages, column: :human_message_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :messages, column: :human_message_id
    add_foreign_key :captain_shadow_training_candidates, :accounts, column: :account_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_candidates, :accounts, column: :account_id
    add_foreign_key :captain_shadow_training_candidates, :captain_shadow_training_runs, column: :run_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_candidates, :captain_shadow_training_runs, column: :run_id
  end''',
    ),
}

AI_PROTECTED_OPERATIONS = {
    'db/migrate/20261102013100_add_pending_ai_usage_index_to_messages.rb': (
        r'''    remove_index :messages, name: 'idx_messages_pending_ai_usage', algorithm: :concurrently unless definition['indisvalid']''',
    ),
    'db/migrate/20261102093000_manage_organization_billing_foundation.rb': (
        r'''    change_column_default table, :foundation_state, from: 'legacy_pending', to: 'ready'
'''.rstrip('\n'),
        r'''    change_column_null :billing_subscriptions, :billing_plan_id, true''',
        r'''    remove_foreign_key :billing_account_workspaces, name: key.name''',
        r'''    add_exclusion_constraint :billing_account_workspaces,
                             "account_id WITH =, tsrange(starts_at, detached_at, '[)') WITH &&",
                             using: :gist, where: "foundation_state = 'ready'", name: 'excl_billing_workspace_intervals'
'''.rstrip('\n'),
    ),
}

# Required final validated constraints are checked separately from admission of
# lock-heavy statements. NOT VALID without the matching validation is unfinished.
AI_FINAL_CHECKS = {
    "db/migrate/20261102093000_manage_organization_billing_foundation.rb": (
        (":billing_accounts", "'chk_billing_accounts_status'"),
        (":billing_accounts", "'chk_billing_accounts_currency'"),
        (":billing_account_workspaces", "'chk_billing_workspaces_status'"),
        (":billing_account_workspaces", "'chk_billing_workspaces_detached_at'"),
        (":billing_subscriptions", "'chk_billing_subscriptions_status'"),
        (":billing_subscriptions", "'chk_billing_subscriptions_period'"),
        ("table", '"chk_#{table}_foundation_state"'),
        (":billing_accounts", "'chk_billing_accounts_explicit_owner'"),
        (":billing_account_workspaces", "'chk_billing_workspaces_known_interval'"),
        (":billing_subscriptions", "'chk_billing_subscriptions_snapshot_contract'"),
    ),
    "db/migrate/20261102103000_create_billing_unit_ledger.rb": (
        (":billing_usage_periods", "'chk_billing_usage_period_month'"),
        (":billing_usage_periods", "'chk_billing_usage_period_units'"),
        (":billing_usage_periods", "'chk_billing_usage_period_anchor'"),
        (":billing_usage_periods", "'chk_billing_usage_period_terms'"),
        (":billing_usage_projections", "'chk_billing_usage_projection_identity'"),
        (":billing_usage_projections", "'chk_billing_usage_projection_retirement'"),
        (":billing_usage_projections", "'chk_billing_usage_projection_payload'"),
        (":billing_usage_revisions", "'chk_billing_usage_revision_nonzero'"),
    ),
}


def ai_expand_contract_intact(path: str, content: str) -> bool:
    guards = AI_EXPAND_GUARDS[path]
    if not all(content.count(block) == 1 for block in guards):
        return False
    definitions = re.findall(r"^\s*def\s+([^\s(]+)", strip_ruby_comments(content), re.MULTILINE)
    if len(definitions) != len(set(definitions)):
        return False
    if path == "db/migrate/20261102103000_create_billing_unit_ledger.rb":
        invocations = (
            "    add_index :billing_usage_periods, %i[billing_account_id month], unique: true, name: 'idx_billing_usage_period_owner_month'\n    period_constraints\n  end",
            "    add_index :billing_usage_projections, %i[account_id kind subject_id], unique: true, name: 'idx_billing_usage_projection_subject'\n    projection_constraints\n  end",
        )
        if not all(content.count(block) == 1 for block in invocations):
            return False
    # An appended Ruby method override must not bypass the exact earlier guard.
    for block in guards:
        match = re.match(r"  def ([^\s(]+)", block)
        if match and len(re.findall(r"\bdef\s+" + re.escape(match[1]) + r"(?=[\s(;])", content)) != 1:
            return False
    if path == "db/migrate/20261102093000_manage_organization_billing_foundation.rb":
        expected_foreign_keys = [
            ":billing_account_workspaces, :billing_accounts, validate: false",
            ":billing_subscriptions, :billing_accounts, validate: false",
            ":billing_account_workspaces, :accounts, validate: false",
            ":billing_accounts, :organizations, validate: false",
            ":billing_accounts, :accounts, column: :standalone_account_id, validate: false",
            ":billing_account_workspaces, :accounts, validate: false",
        ]
        actual = [" ".join(args.split()) for args in calls(content, "add_foreign_key")]
        if actual != expected_foreign_keys:
            return False
        for args in expected_foreign_keys:
            validation = "validate_foreign_key " + args.replace(", validate: false", "")
            expected_count = expected_foreign_keys.count(args)
            if content.count(validation + "\n") != expected_count:
                return False
    for table, name in AI_FINAL_CHECKS.get(path, ()):
        add = [args for args in calls(content, "add_check_constraint")
               if re.match(r"\s*" + re.escape(table) + r"\s*,", args) and "name: " + name in args]
        validation = f"    validate_check_constraint {table}, name: {name}"
        if len(add) != 1 or not NOT_VALID_PATTERN.search(add[0]) or content.count(validation) != 1:
            return False
        if content.index(validation) < content.index("add_check_constraint" + add[0]):
            return False
    return True


# Production runs migrations while the previous release is still serving, so an
# "expand" migration must also be cheap and short-locked, not only additive.
# These rules flag the statements that hold a strong lock for as long as the
# table is large; each one has a safe form (see script/onelink/README.md).
UNSAFE_UPDATE_PATTERN = re.compile(r"\bUPDATE\s+\S+\s+SET\b|\.update_all\b", re.IGNORECASE)
BATCHING_MARKER_PATTERN = re.compile(
    r"\b(in_batches|find_in_batches|find_each|each_batch|each_id_range|BATCH_SIZE)\b"
    r"|\bLIMIT\s+(\d|#\{)",
    re.IGNORECASE,
)
CREATE_TABLE_PATTERN = re.compile(r"\bcreate_table\s*\(?\s*:(\w+)")
FIRST_TABLE_ARGUMENT_PATTERN = re.compile(r"\(?\s*:(\w+)")
ENFORCED_FOREIGN_KEY_PATTERN = re.compile(r"foreign_key:\s*(true\b|\{)")
CONCURRENT_INDEX_PATTERN = re.compile(r"algorithm:\s*:concurrently")
UNINDEXED_REFERENCE_PATTERN = re.compile(r"index:\s*(false\b|\{[^}]*algorithm:\s*:concurrently)")
NOT_VALID_PATTERN = re.compile(r"validate:\s*false\b")


def strip_ruby_comments(content: str) -> str:
    return "\n".join(
        line for line in content.splitlines() if not line.lstrip().startswith("#")
    )


def statement_arguments(content: str, start: int) -> str:
    """Return the arguments of the Ruby call that begins at ``start``.

    The call ends at the first newline outside brackets and quotes that does not
    continue the expression (trailing comma, operator or backslash).
    """
    depth = 0
    quote = ""
    index = start
    while index < len(content):
        char = content[index]
        if quote:
            if char == "\\":
                index += 1
            elif char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "\n" and depth <= 0:
            before = content[start:index].rstrip()
            following = content[index:].lstrip()
            if not (before.endswith((",", "\\", "(", "||", "&&", "+")) or following.startswith(".")):
                break
        index += 1
    return content[start:index]


def calls(content: str, name: str) -> list[str]:
    pattern = re.compile(rf"(?<![\w:])(?:\w+\.)?{re.escape(name)}\b")
    return [statement_arguments(content, match.end()) for match in pattern.finditer(content)]


def unsafe_migration_rules(content: str) -> list[str]:
    """Names the lock-heavy statements in a migration; empty when it is a safe expand."""
    code = strip_ruby_comments(content)
    created_tables = set(CREATE_TABLE_PATTERN.findall(code))
    rules: list[str] = []

    def on_existing_table(arguments: str) -> bool:
        match = FIRST_TABLE_ARGUMENT_PATTERN.match(arguments)
        return not (match and match.group(1) in created_tables)

    if any(
        on_existing_table(arguments) and not CONCURRENT_INDEX_PATTERN.search(arguments)
        for arguments in calls(code, "add_index")
    ):
        rules.append("add_index without algorithm: :concurrently")
    if any(not NOT_VALID_PATTERN.search(arguments) for arguments in calls(code, "add_foreign_key")):
        rules.append("add_foreign_key without validate: false")
    if any(not NOT_VALID_PATTERN.search(arguments) for arguments in calls(code, "add_check_constraint")):
        rules.append("add_check_constraint without validate: false")
    references = calls(code, "add_reference") + calls(code, "add_belongs_to")
    if any(
        on_existing_table(arguments)
        and (ENFORCED_FOREIGN_KEY_PATTERN.search(arguments) or not UNINDEXED_REFERENCE_PATTERN.search(arguments))
        for arguments in references
    ):
        rules.append("add_reference with a foreign key or a non-concurrent index")
    table_references = calls(code, "t.references") + calls(code, "t.belongs_to")
    if any(ENFORCED_FOREIGN_KEY_PATTERN.search(arguments) for arguments in table_references):
        rules.append("create_table references with an enforced foreign key")
    if calls(code, "add_exclusion_constraint"):
        rules.append("add_exclusion_constraint requires a bounded maintenance guard")
    if UNSAFE_UPDATE_PATTERN.search(code) and not BATCHING_MARKER_PATTERN.search(code):
        rules.append("UPDATE of existing rows without batches")
    return rules



def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], check=True, text=True, stdout=subprocess.PIPE
    ).stdout


def changed_files(base: str, head: str) -> list[str]:
    output = git("diff", "--name-only", "--diff-filter=ACMRD", base, head)
    return sorted({line.strip() for line in output.splitlines() if line.strip()})


def classify(paths: Iterable[str]) -> dict[str, bool]:
    files = list(paths)
    backend = any(
        Path(path).suffix in RUBY_SUFFIXES
        or path.startswith(RUBY_ROOTS)
        or path in {"Gemfile", "Gemfile.lock"}
        for path in files
    )
    frontend = any(
        not path.startswith(SIDECAR_ROOTS)
        and (
            Path(path).suffix in FRONTEND_SUFFIXES
            or path.startswith(FRONTEND_ROOTS)
            or path in {"package.json", "pnpm-lock.yaml", "vite.config.mts"}
        )
        for path in files
    )
    migrations = any(path.startswith("db/migrate/") for path in files)
    container = any(
        path in CONTAINER_FILES
        or path.endswith("/Dockerfile")
        or path.startswith("docker-compose")
        or path.startswith("docker/")
        for path in files
    )
    high_risk = any(path.startswith(HIGH_RISK_ROOTS) for path in files)
    sidecar = any(path.startswith(SIDECAR_ROOTS) for path in files)
    runtime = any(
        not path.startswith(("docs/", ".github/"))
        and not path.lower().endswith((".md", ".mdx"))
        for path in files
    )
    return {
        "backend": backend,
        "container": container,
        "frontend": frontend,
        "high_risk": high_risk,
        "migrations": migrations,
        "runtime": runtime,
        "sidecar": sidecar,
    }


def related_specs(paths: Iterable[str]) -> list[str]:
    specs: set[str] = set()
    for raw_path in paths:
        path = Path(raw_path)
        if raw_path.startswith("spec/") and raw_path.endswith("_spec.rb"):
            if path.is_file():
                specs.add(raw_path)
            continue
        if path.suffix != ".rb":
            continue
        for prefix, companions in COMPANION_SPECS.items():
            if raw_path.startswith(prefix):
                specs.update(spec for spec in companions if Path(spec).is_file())
        if raw_path.startswith("enterprise/app/"):
            candidate = Path("spec/enterprise") / Path(raw_path).relative_to("enterprise/app")
        elif raw_path.startswith("app/"):
            candidate = Path("spec") / Path(raw_path).relative_to("app")
        elif raw_path.startswith("lib/"):
            candidate = Path("spec") / path
        else:
            continue
        candidate = candidate.with_name(f"{candidate.stem}_spec.rb")
        if candidate.is_file():
            specs.add(candidate.as_posix())
    return sorted(specs)


def existing_files_with_suffixes(paths: Iterable[str], suffixes: set[str]) -> list[str]:
    return sorted(
        path for path in paths if Path(path).suffix in suffixes and Path(path).is_file()
    )


def frontend_files(paths: Iterable[str]) -> list[str]:
    return existing_files_with_suffixes(
        (path for path in paths if not path.startswith(SIDECAR_ROOTS)),
        FRONTEND_SUFFIXES,
    )


def protected_expand_content(raw_path: str, content: str) -> str:
    """Exclude only an exact, migration-specific safe operation from the ban."""
    if raw_path in AI_EXPAND_GUARDS:
        required = AI_EXPAND_GUARDS[raw_path]
        if ai_expand_contract_intact(raw_path, content):
            for block in AI_PROTECTED_OPERATIONS.get(raw_path, ()):
                content = content.replace(block, "", 1)
        return content
    if raw_path == SAFE_SCENARIO_HISTORY_MIGRATION:
        protected = SAFE_SCENARIO_HISTORY_BLOCK
        required = (SAFE_SHORT_LOCK_SETTINGS, SAFE_SHORT_LOCK_BLOCK, protected)
    elif raw_path == SAFE_CRM_TARGET_INDEX_MIGRATION:
        protected = SAFE_CRM_TARGET_INDEX_SWAP_BLOCK
        required = (protected, *SAFE_CRM_TARGET_INDEX_GUARDS)
    else:
        return content
    if all(content.count(block) == 1 for block in required):
        return content.replace(protected, "", 1)
    return content


def migration_violations(paths: Iterable[str]) -> list[tuple[str, str]]:
    """Return (path, rule) for every changed migration that is not a safe expand."""
    violations: list[tuple[str, str]] = []
    for raw_path in paths:
        if not raw_path.startswith("db/migrate/") or not raw_path.endswith(".rb"):
            continue
        path = Path(raw_path)
        if not path.is_file():
            continue
        content = path.read_text(encoding="utf-8")
        if raw_path == SAFE_STAGE_VISIT_UUID_DEFAULT_MIGRATION:
            content = SAFE_STAGE_VISIT_UUID_DEFAULT_BLOCK.sub("", content)
        if raw_path in AI_EXPAND_GUARDS and not ai_expand_contract_intact(raw_path, content):
            violations.append((raw_path, "reviewed AI expand safety contract changed"))
        content = protected_expand_content(raw_path, content)
        if DESTRUCTIVE_MIGRATION_PATTERN.search(content):
            violations.append((raw_path, "destructive or contracting schema change"))
        violations.extend((raw_path, rule) for rule in unsafe_migration_rules(content))
    return violations


def validate_migrations(paths: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(path for path, _ in migration_violations(paths)))


def unsupported_release_sidecars(paths: Iterable[str]) -> list[str]:
    return sorted(
        path
        for path in paths
        if path.startswith(SIDECAR_ROOTS)
        and not path.startswith(IMMUTABLE_RELEASE_SIDECAR_ROOTS)
    )


def emit_github_output(path: Path, plan: dict[str, bool], files: list[str]) -> None:
    with path.open("a", encoding="utf-8") as output:
        for key, value in sorted(plan.items()):
            output.write(f"{key}={'true' if value else 'false'}\n")
        output.write(f"changed_count={len(files)}\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument(
        "--list", choices=("files", "ruby", "frontend", "specs", "migrations")
    )
    parser.add_argument("--validate-migrations", action="store_true")
    parser.add_argument("--validate-release-surface", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    files = changed_files(args.base, args.head)
    plan = classify(files)

    if args.github_output:
        emit_github_output(args.github_output, plan, files)

    if args.list:
        selected = files
        if args.list == "ruby":
            selected = existing_files_with_suffixes(files, RUBY_SUFFIXES)
        elif args.list == "frontend":
            selected = frontend_files(files)
        elif args.list == "specs":
            selected = related_specs(files)
        elif args.list == "migrations":
            selected = [path for path in files if path.startswith("db/migrate/")]
        sys.stdout.write("".join(f"{path}\n" for path in selected))
    elif not args.github_output:
        print(json.dumps({"files": files, "plan": plan}, sort_keys=True))

    if args.validate_migrations:
        violations = migration_violations(files)
        if violations:
            print(
                "Automatic releases accept short-locked expand migrations only (additive, "
                "NOT VALID keys and checks, concurrent indexes, batched backfills). "
                "Run destructive contract cleanup as a separate reviewed maintenance task:",
                file=sys.stderr,
            )
            for path, rule in violations:
                print(f"  - {path}: {rule}", file=sys.stderr)
            return 2
    if args.validate_release_surface:
        sidecar_files = unsupported_release_sidecars(files)
        if sidecar_files:
            print(
                "This release changes sidecars that are not covered by the immutable "
                "release workflow:",
                file=sys.stderr,
            )
            for path in sidecar_files:
                print(f"  - {path}", file=sys.stderr)
            return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
