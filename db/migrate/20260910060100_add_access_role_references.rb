# rubocop:disable Metrics/MethodLength
class AddAccessRoleReferences < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  ACCOUNT_USER_TABLE = :account_users
  SNAPSHOT_TABLE = :account_user_lifecycle_snapshots
  ACCESS_ROLE_COLUMN = :access_role_id
  ACCOUNT_USER_ROLE_INDEX = 'index_account_users_on_access_role_id'.freeze
  ACCOUNT_USER_ACCOUNT_ROLE_INDEX = 'index_account_users_on_account_and_access_role'.freeze
  SNAPSHOT_ROLE_INDEX = 'index_account_user_lifecycle_snapshots_on_access_role_id'.freeze
  SNAPSHOT_ACCOUNT_ROLE_INDEX = 'index_lifecycle_snapshots_on_account_and_access_role'.freeze
  SNAPSHOT_CUSTOM_ROLE_INDEX = 'index_lifecycle_snapshots_on_account_and_custom_role'.freeze
  ACCOUNT_USER_ROLE_FK = 'fk_account_users_access_role'.freeze
  ACCOUNT_USER_ACCOUNT_ROLE_FK = 'fk_account_users_access_role_account'.freeze
  SNAPSHOT_ROLE_FK = 'fk_lifecycle_snapshots_access_role'.freeze
  SNAPSHOT_ACCOUNT_ROLE_FK = 'fk_lifecycle_snapshots_access_role_account'.freeze
  SNAPSHOT_CUSTOM_ROLE_FK = 'fk_lifecycle_snapshots_custom_role_account'.freeze

  def up
    add_account_user_access_role
    add_lifecycle_snapshot_role_references
  end

  def down
    remove_lifecycle_snapshot_role_references
    remove_account_user_access_role
  end

  private

  def add_account_user_access_role
    ensure_bigint_column(ACCOUNT_USER_TABLE, ACCESS_ROLE_COLUMN)
    ensure_concurrent_index(ACCOUNT_USER_TABLE, [ACCESS_ROLE_COLUMN], ACCOUNT_USER_ROLE_INDEX)
    ensure_concurrent_index(
      ACCOUNT_USER_TABLE,
      [:account_id, ACCESS_ROLE_COLUMN],
      ACCOUNT_USER_ACCOUNT_ROLE_INDEX
    )
    ensure_foreign_key(
      ACCOUNT_USER_TABLE,
      :access_roles,
      column: ACCESS_ROLE_COLUMN,
      primary_key: :id,
      name: ACCOUNT_USER_ROLE_FK
    )
    ensure_foreign_key(
      ACCOUNT_USER_TABLE,
      :access_roles,
      column: [:account_id, ACCESS_ROLE_COLUMN],
      primary_key: [:account_id, :id],
      name: ACCOUNT_USER_ACCOUNT_ROLE_FK
    )
  end

  def add_lifecycle_snapshot_role_references
    ensure_bigint_column(SNAPSHOT_TABLE, ACCESS_ROLE_COLUMN)
    ensure_concurrent_index(SNAPSHOT_TABLE, [ACCESS_ROLE_COLUMN], SNAPSHOT_ROLE_INDEX)
    ensure_concurrent_index(
      SNAPSHOT_TABLE,
      [:account_id, ACCESS_ROLE_COLUMN],
      SNAPSHOT_ACCOUNT_ROLE_INDEX
    )
    ensure_concurrent_index(
      SNAPSHOT_TABLE,
      [:account_id, :custom_role_id],
      SNAPSHOT_CUSTOM_ROLE_INDEX
    )
    ensure_foreign_key(
      SNAPSHOT_TABLE,
      :access_roles,
      column: ACCESS_ROLE_COLUMN,
      primary_key: :id,
      name: SNAPSHOT_ROLE_FK
    )
    ensure_foreign_key(
      SNAPSHOT_TABLE,
      :access_roles,
      column: [:account_id, ACCESS_ROLE_COLUMN],
      primary_key: [:account_id, :id],
      name: SNAPSHOT_ACCOUNT_ROLE_FK
    )
    ensure_foreign_key(
      SNAPSHOT_TABLE,
      :custom_roles,
      column: [:account_id, :custom_role_id],
      primary_key: [:account_id, :id],
      name: SNAPSHOT_CUSTOM_ROLE_FK
    )
  end

  def remove_lifecycle_snapshot_role_references
    remove_foreign_key_if_present(SNAPSHOT_TABLE, SNAPSHOT_CUSTOM_ROLE_FK)
    remove_concurrent_index_if_present(SNAPSHOT_TABLE, SNAPSHOT_CUSTOM_ROLE_INDEX)
    remove_foreign_key_if_present(SNAPSHOT_TABLE, SNAPSHOT_ACCOUNT_ROLE_FK)
    remove_foreign_key_if_present(SNAPSHOT_TABLE, SNAPSHOT_ROLE_FK)
    remove_concurrent_index_if_present(SNAPSHOT_TABLE, SNAPSHOT_ACCOUNT_ROLE_INDEX)
    remove_concurrent_index_if_present(SNAPSHOT_TABLE, SNAPSHOT_ROLE_INDEX)
    remove_column SNAPSHOT_TABLE, ACCESS_ROLE_COLUMN if column_exists?(SNAPSHOT_TABLE, ACCESS_ROLE_COLUMN)
  end

  def remove_account_user_access_role
    remove_foreign_key_if_present(ACCOUNT_USER_TABLE, ACCOUNT_USER_ACCOUNT_ROLE_FK)
    remove_foreign_key_if_present(ACCOUNT_USER_TABLE, ACCOUNT_USER_ROLE_FK)
    remove_concurrent_index_if_present(ACCOUNT_USER_TABLE, ACCOUNT_USER_ACCOUNT_ROLE_INDEX)
    remove_concurrent_index_if_present(ACCOUNT_USER_TABLE, ACCOUNT_USER_ROLE_INDEX)
    remove_column ACCOUNT_USER_TABLE, ACCESS_ROLE_COLUMN if column_exists?(ACCOUNT_USER_TABLE, ACCESS_ROLE_COLUMN)
  end

  def ensure_bigint_column(table, column)
    existing_column = connection.columns(table).find { |candidate| candidate.name == column.to_s }
    unless existing_column
      add_column table, column, :bigint
      return
    end
    return if existing_column.sql_type == 'bigint' && existing_column.null

    raise ActiveRecord::MigrationError, "Existing #{table}.#{column} is incompatible with the access role contract"
  end

  def ensure_concurrent_index(table, columns, name)
    expected_columns = columns.map(&:to_s)
    existing_index = connection.indexes(table).find { |index| index.name == name }
    if existing_index
      raise ActiveRecord::MigrationError, "Existing #{name} has an incompatible definition" unless compatible_index?(existing_index, expected_columns)

      return if existing_index.valid

      remove_index table, name: name, algorithm: :concurrently
    end

    add_index table, columns, name: name, algorithm: :concurrently
  end

  def compatible_index?(index, columns)
    !index.unique &&
      index.columns == columns &&
      index.where.nil? &&
      index.using == :btree &&
      index.type.nil? &&
      index.opclasses.empty?
  end

  def ensure_foreign_key(from_table, to_table, column:, primary_key:, name:)
    expected_columns = Array(column).map(&:to_s)
    expected_primary_keys = Array(primary_key).map(&:to_s)
    existing_key = connection.foreign_keys(from_table).find { |foreign_key| foreign_key.name == name }
    if existing_key
      return if foreign_key_compatible?(existing_key, to_table, expected_columns, expected_primary_keys)

      raise ActiveRecord::MigrationError, "Existing #{name} has an incompatible definition"
    end

    add_foreign_key from_table,
                    to_table,
                    column: column,
                    primary_key: primary_key,
                    validate: false,
                    name: name
  end

  def foreign_key_compatible?(foreign_key, to_table, columns, primary_keys)
    foreign_key.to_table.to_s == to_table.to_s &&
      Array(foreign_key.column).map(&:to_s) == columns &&
      Array(foreign_key.primary_key).map(&:to_s) == primary_keys &&
      non_cascading_foreign_key?(foreign_key)
  end

  def non_cascading_foreign_key?(foreign_key)
    foreign_key.on_delete.nil? && foreign_key.on_update.nil? && foreign_key.deferrable == false
  end

  def remove_concurrent_index_if_present(table, name)
    return unless connection.indexes(table).any? { |index| index.name == name }

    remove_index table, name: name, algorithm: :concurrently
  end

  def remove_foreign_key_if_present(table, name)
    return unless connection.foreign_keys(table).any? { |foreign_key| foreign_key.name == name }

    remove_foreign_key table, name: name
  end
end
# rubocop:enable Metrics/MethodLength
