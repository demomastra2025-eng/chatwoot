require 'rails_helper'
require Rails.root.join('db/migrate/20260901140000_add_automation_lifecycle_generations').to_s

# Intentional method-level migration isolation requires stubbing the migration connection.
# rubocop:disable RSpec/SubjectStub, RSpec/VerifiedDoubles
RSpec.describe AddAutomationLifecycleGenerations do
  subject(:migration) { described_class.new }

  describe 'partial-state recovery' do
    it 'accepts an existing compatible bigint column without recreating it' do
      column = Struct.new(:name, :sql_type, :default, :null).new(
        'lifecycle_generation', 'bigint', '1', false
      )
      connection = double('connection', columns: [column], column_exists?: true)
      allow(migration).to receive(:connection).and_return(connection)

      expect(connection).not_to receive(:add_column)

      migration.send(
        :ensure_bigint_column!,
        :automation_rules,
        :lifecycle_generation,
        default: 1,
        null: false
      )
    end

    it 'fails closed when an existing generation column is incompatible' do
      column = Struct.new(:name, :sql_type, :default, :null).new(
        'lifecycle_generation', 'integer', '1', false
      )
      connection = double('connection', columns: [column], column_exists?: true)
      allow(migration).to receive(:connection).and_return(connection)

      expect do
        migration.send(
          :ensure_bigint_column!,
          :automation_rules,
          :lifecycle_generation,
          default: 1,
          null: false
        )
      end.to raise_error(ActiveRecord::MigrationError, /incompatible/)
    end

    it 'drops and recreates an interrupted invalid concurrent index' do
      index = Struct.new(:name, :unique, :columns, :where).new(
        described_class::GENERATION_INDEX,
        true,
        described_class::GENERATION_INDEX_COLUMNS,
        "status IN ('active', 'paused', 'completed') AND automation_rule_id IS NOT NULL"
      )
      connection = double('connection', indexes: [index])
      allow(migration).to receive(:connection).and_return(connection)
      allow(migration).to receive(:postgres_index_valid?).and_return(false)

      expect(connection).to receive(:remove_index).with(
        'touch_plan_enrollments',
        name: described_class::GENERATION_INDEX,
        algorithm: :concurrently
      ).ordered
      expect(connection).to receive(:add_index).with(
        'touch_plan_enrollments',
        described_class::GENERATION_INDEX_COLUMNS,
        name: described_class::GENERATION_INDEX,
        unique: true,
        where: "#{described_class::OPEN_ENROLLMENT_STATUS_SQL} AND automation_rule_id IS NOT NULL",
        algorithm: :concurrently
      ).ordered

      migration.send(:ensure_generation_index!)
    end

    it 'replaces the function and recreates the trigger idempotently' do
      connection = double('connection')
      allow(migration).to receive(:connection).and_return(connection)
      expect(connection).to receive(:execute) do |sql|
        expect(sql).to include('CREATE OR REPLACE FUNCTION bump_automation_rule_lifecycle_generation()')
        expect(sql).to include('DROP TRIGGER IF EXISTS bump_automation_rule_lifecycle_generation ON automation_rules')
        expect(sql).to include('CREATE TRIGGER bump_automation_rule_lifecycle_generation')
      end

      migration.send(:create_lifecycle_generation_trigger)
    end
  end
end
# rubocop:enable RSpec/SubjectStub, RSpec/VerifiedDoubles
