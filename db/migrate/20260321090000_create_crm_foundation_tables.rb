class CreateCrmFoundationTables < ActiveRecord::Migration[7.0]
  def change
    create_crm_pipelines_table
    create_crm_stages_table
    create_crm_task_statuses_table
    create_crm_field_definitions_table
  end

  private

  def create_crm_pipelines_table
    create_table :crm_pipelines do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :code, null: false
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.boolean :default, null: false, default: false

      t.timestamps
    end

    add_index :crm_pipelines, [:account_id, :code], unique: true
    add_index :crm_pipelines,
              :account_id,
              unique: true,
              where: '("default" = true AND active = true)',
              name: 'index_crm_pipelines_on_account_default_active'
  end

  def create_crm_stages_table
    create_table :crm_stages do |t|
      t.references :account, null: false, foreign_key: true
      t.references :pipeline, null: false, foreign_key: { to_table: :crm_pipelines }
      t.string :name, null: false
      t.string :code, null: false
      t.integer :position, null: false, default: 0
      t.string :outcome, null: false, default: 'open'
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :crm_stages, [:pipeline_id, :code], unique: true
    add_index :crm_stages, [:account_id, :pipeline_id, :position], name: 'index_crm_stages_on_account_pipeline_position'
  end

  def create_crm_task_statuses_table
    create_table :crm_task_statuses do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :code, null: false
      t.integer :position, null: false, default: 0
      t.string :category, null: false, default: 'open'
      t.boolean :active, null: false, default: true
      t.boolean :default, null: false, default: false

      t.timestamps
    end

    add_index :crm_task_statuses, [:account_id, :code], unique: true
    add_index :crm_task_statuses,
              :account_id,
              unique: true,
              where: %q(("default" = true AND category = 'open')),
              name: 'index_crm_task_statuses_on_account_default_open'
  end

  def create_crm_field_definitions_table
    create_table :crm_field_definitions do |t|
      t.references :account, null: false, foreign_key: true
      t.string :entity_kind, null: false
      t.string :key, null: false
      t.string :label, null: false
      t.text :description
      t.string :field_type, null: false
      t.boolean :required, null: false, default: false
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0
      t.jsonb :default_value
      t.jsonb :options, null: false, default: []
      t.jsonb :rules, null: false, default: {}

      t.timestamps
    end

    add_crm_field_definition_indexes
  end

  def add_crm_field_definition_indexes
    add_index :crm_field_definitions,
              [:account_id, :entity_kind, :key],
              unique: true,
              name: 'index_crm_field_defs_on_account_kind_key'
    add_index :crm_field_definitions,
              [:account_id, :entity_kind, :active, :position],
              name: 'index_crm_field_definitions_on_account_entity_active_position'
  end
end
