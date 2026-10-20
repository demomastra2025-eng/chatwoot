# frozen_string_literal: true

class CreateCaptainKnowledgeGraph < ActiveRecord::Migration[7.1]
  def change
    create_knowledge_nodes_table
    create_knowledge_edges_table
  end

  private

  def create_knowledge_nodes_table
    create_table :captain_knowledge_nodes do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.bigint :assistant_id
      t.integer :visibility, null: false, default: 0
      t.string :node_type, null: false
      t.string :canonical_name, null: false
      t.string :normalized_key, null: false
      t.string :aliases, array: true, default: [], null: false
      t.string :search_stems, array: true, default: [], null: false
      t.jsonb :attributes_data, default: {}, null: false
      t.bigint :evidence_response_ids, array: true, default: [], null: false
      t.string :source_type
      t.bigint :source_id
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end
    add_node_indexes
  end

  def add_node_indexes
    add_index :captain_knowledge_nodes, %i[account_id node_type normalized_key],
              unique: true, name: 'idx_captain_kg_nodes_account_type_norm_key'
    add_index :captain_knowledge_nodes, %i[account_id assistant_id visibility],
              name: 'idx_captain_kg_nodes_account_visibility'
    add_index :captain_knowledge_nodes, :search_stems,
              using: :gin, name: 'idx_captain_kg_nodes_search_stems_gin'
    add_index :captain_knowledge_nodes, :attributes_data,
              using: :gin, name: 'idx_captain_kg_nodes_attributes_gin'
  end

  def create_knowledge_edges_table
    create_table :captain_knowledge_edges do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :source_node, null: false, foreign_key: { to_table: :captain_knowledge_nodes }
      t.references :target_node, null: false, foreign_key: { to_table: :captain_knowledge_nodes }
      t.string :relation_type, null: false
      t.jsonb :properties, default: {}, null: false
      t.bigint :evidence_response_id
      t.timestamps
    end

    add_index :captain_knowledge_edges, %i[account_id source_node_id relation_type target_node_id],
              unique: true, name: 'idx_captain_kg_edges_unique_triplet'
    add_index :captain_knowledge_edges, %i[account_id relation_type],
              name: 'idx_captain_kg_edges_account_relation'
  end
end
