class CreateWhatsappUsageExchangeRates < ActiveRecord::Migration[7.1]
  def change
    create_table :whatsapp_usage_exchange_rates do |t|
      t.date :month_start, null: false
      t.date :requested_date, null: false
      t.date :effective_date
      t.decimal :rate_per_usd, precision: 20, scale: 10
      t.decimal :nominal_rate, precision: 20, scale: 10
      t.integer :nominal_units
      t.string :status, null: false, default: 'unavailable'
      t.string :source_url
      t.datetime :fetched_at, precision: 6
      t.datetime :retry_after, precision: 6
      t.string :error_code, limit: 64

      t.timestamps
    end

    add_index :whatsapp_usage_exchange_rates, :month_start, unique: true,
                                                            name: 'index_whatsapp_usage_exchange_rates_on_month_start'
  end
end
