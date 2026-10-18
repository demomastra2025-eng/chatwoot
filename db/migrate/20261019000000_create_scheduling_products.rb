class CreateSchedulingProducts < ActiveRecord::Migration[7.1]
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def change
    create_table :scheduling_products do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.string :name, null: false
      t.string :item_type, null: false, default: 'product'
      t.string :code
      t.string :article
      t.string :category
      t.string :uom, null: false, default: 'шт'
      t.text :description
      t.bigint :price, null: false, default: 0
      t.bigint :wholesale_price
      t.bigint :kaspi_price
      t.bigint :buy_price, null: false, default: 0
      t.bigint :min_price, null: false, default: 0
      t.string :currency, null: false, default: 'KZT'
      t.decimal :stock, precision: 14, scale: 3, null: false, default: 0
      t.decimal :reserve, precision: 14, scale: 3, null: false, default: 0
      t.decimal :in_transit, precision: 14, scale: 3, null: false, default: 0
      t.decimal :quantity, precision: 14, scale: 3, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.string :external_source
      t.string :external_id
      t.string :parent_external_id
      t.jsonb :barcodes, null: false, default: []
      t.jsonb :characteristics, null: false, default: []
      t.jsonb :sale_prices, null: false, default: []
      t.jsonb :store_stocks, null: false, default: []
      t.jsonb :custom_attributes, null: false, default: {}
      t.datetime :synced_at

      t.timestamps
    end

    add_index :scheduling_products,
              [:account_id, :external_source, :external_id],
              unique: true,
              where: 'external_source IS NOT NULL AND external_id IS NOT NULL',
              name: 'idx_scheduling_products_on_account_and_external'
    add_index :scheduling_products, [:account_id, :active]
    add_index :scheduling_products, [:account_id, :category]
    add_index :scheduling_products, [:account_id, :item_type]
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
end
