class AddAutomationLifecycleGenerations < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  OPEN_ENROLLMENT_STATUS_SQL = "status IN ('active', 'paused', 'completed')".freeze
  OLD_INDEX = 'idx_touch_plan_enrollments_one_open_action'.freeze
  GENERATION_INDEX = 'idx_touch_plan_enrollments_one_open_action_generation'.freeze
  GENERATION_INDEX_COLUMNS = %w[account_id automation_rule_id source_generation source_action_id remindable_type remindable_id].freeze

  def up
    ensure_bigint_column!(:automation_rules, :lifecycle_generation, default: 1, null: false)
    ensure_bigint_column!(:touch_plan_enrollments, :source_generation, default: 1, null: true)

    create_lifecycle_generation_trigger

    execute <<~SQL.squish
      UPDATE touch_plan_enrollments
      SET source_generation = 1
      WHERE automation_rule_id IS NOT NULL AND source_generation IS NULL
    SQL

    ensure_generation_index!
    remove_index :touch_plan_enrollments, name: OLD_INDEX, algorithm: :concurrently if index_exists?(:touch_plan_enrollments, name: OLD_INDEX)
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Lifecycle generations protect automation delivery correctness'
  end

  private

  def ensure_bigint_column!(table, column_name, default:, null:)
    unless column_exists?(table, column_name)
      add_column table, column_name, :bigint, default: default, null: null
      return
    end

    column = connection.columns(table).find { |candidate| candidate.name == column_name.to_s }
    compatible = column&.sql_type == 'bigint' && column.default.to_i == default && column.null == null
    return if compatible

    raise ActiveRecord::MigrationError,
          "Existing #{table}.#{column_name} is incompatible with lifecycle generation contract"
  end

  def ensure_generation_index!
    existing_index = connection.indexes(:touch_plan_enrollments).find { |index| index.name == GENERATION_INDEX }
    if existing_index
      validate_generation_index!(existing_index)
      return if postgres_index_valid?(GENERATION_INDEX)

      remove_index :touch_plan_enrollments, name: GENERATION_INDEX, algorithm: :concurrently
    end

    add_index :touch_plan_enrollments,
              GENERATION_INDEX_COLUMNS,
              name: GENERATION_INDEX,
              unique: true,
              where: "#{OPEN_ENROLLMENT_STATUS_SQL} AND automation_rule_id IS NOT NULL",
              algorithm: :concurrently
  end

  def validate_generation_index!(index)
    normalized_where = index.where.to_s.downcase
    required_predicate_tokens = %w[status active paused completed automation_rule_id]
    compatible_predicate = required_predicate_tokens.all? { |token| normalized_where.include?(token) } &&
                           normalized_where.include?('is not null') && normalized_where.include?('and')
    compatible = index.unique && index.columns == GENERATION_INDEX_COLUMNS && compatible_predicate
    return if compatible

    raise ActiveRecord::MigrationError, "Existing #{GENERATION_INDEX} has an incompatible definition"
  end

  def postgres_index_valid?(index_name)
    %w[t true 1].include?(connection.select_value(<<~SQL.squish).to_s)
      SELECT pg_index.indisvalid
      FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      WHERE pg_class.relname = #{connection.quote(index_name)}
    SQL
  end

  def create_lifecycle_generation_trigger
    execute <<~SQL.squish
      CREATE OR REPLACE FUNCTION bump_automation_rule_lifecycle_generation()
      RETURNS trigger AS $$
      BEGIN
        IF OLD.active = FALSE AND NEW.active = TRUE AND NEW.lifecycle_generation <= OLD.lifecycle_generation THEN
          NEW.lifecycle_generation := OLD.lifecycle_generation + 1;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      DROP TRIGGER IF EXISTS bump_automation_rule_lifecycle_generation ON automation_rules;
      CREATE TRIGGER bump_automation_rule_lifecycle_generation
      BEFORE UPDATE ON automation_rules
      FOR EACH ROW
      EXECUTE FUNCTION bump_automation_rule_lifecycle_generation();
    SQL
  end
end
