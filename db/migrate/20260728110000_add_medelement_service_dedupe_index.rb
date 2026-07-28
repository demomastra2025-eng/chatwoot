class AddMedelementServiceDedupeIndex < ActiveRecord::Migration[7.1]
  INDEX_NAME = 'idx_scheduling_services_account_medelement_code_unique'.freeze
  CODE_KEY = 'medelement_nomenclature_code'.freeze
  DUPLICATE_CODE_KEY = 'medelement_duplicate_nomenclature_code'.freeze
  DUPLICATE_OF_KEY = 'medelement_duplicate_of_service_id'.freeze
  RANKED_SERVICES_SQL = <<~SQL.squish.freeze
    SELECT scheduling_services.id,
           FIRST_VALUE(scheduling_services.id) OVER (
             PARTITION BY scheduling_services.account_id, scheduling_services.custom_attributes ->> '#{CODE_KEY}'
             ORDER BY scheduling_services.active DESC,
                      (SELECT COUNT(*) FROM scheduling_service_prices
                       WHERE scheduling_service_prices.service_id = scheduling_services.id
                         AND scheduling_service_prices.active = TRUE) DESC,
                      scheduling_services.updated_at DESC,
                      scheduling_services.id ASC
           ) AS keeper_id,
           ROW_NUMBER() OVER (
             PARTITION BY scheduling_services.account_id, scheduling_services.custom_attributes ->> '#{CODE_KEY}'
             ORDER BY scheduling_services.active DESC,
                      (SELECT COUNT(*) FROM scheduling_service_prices
                       WHERE scheduling_service_prices.service_id = scheduling_services.id
                         AND scheduling_service_prices.active = TRUE) DESC,
                      scheduling_services.updated_at DESC,
                      scheduling_services.id ASC
           ) AS duplicate_rank
    FROM scheduling_services
    WHERE scheduling_services.custom_attributes ->> '#{CODE_KEY}' IS NOT NULL
  SQL

  def up
    quarantine_duplicate_services!
    add_index :scheduling_services,
              "account_id, (custom_attributes ->> '#{CODE_KEY}')",
              unique: true,
              where: "custom_attributes ->> '#{CODE_KEY}' IS NOT NULL",
              name: INDEX_NAME
  end

  def down
    remove_index :scheduling_services, name: INDEX_NAME
  end

  private

  def quarantine_duplicate_services!
    deactivate_duplicate_prices!
    execute <<~SQL.squish
      WITH ranked_services AS (
        #{RANKED_SERVICES_SQL}
      )
      UPDATE scheduling_services
      SET active = FALSE,
          custom_attributes = (scheduling_services.custom_attributes - '#{CODE_KEY}') ||
            jsonb_build_object(
              '#{DUPLICATE_CODE_KEY}', scheduling_services.custom_attributes ->> '#{CODE_KEY}',
              '#{DUPLICATE_OF_KEY}', ranked_services.keeper_id
            ),
          updated_at = CURRENT_TIMESTAMP
      FROM ranked_services
      WHERE scheduling_services.id = ranked_services.id
        AND ranked_services.duplicate_rank > 1
    SQL
  end

  def deactivate_duplicate_prices!
    execute <<~SQL.squish
      WITH ranked_services AS (
        #{RANKED_SERVICES_SQL}
      ), duplicate_service_ids AS (
        SELECT id
        FROM ranked_services
        WHERE duplicate_rank > 1
      )
      UPDATE scheduling_service_prices
      SET active = FALSE,
          updated_at = CURRENT_TIMESTAMP
      FROM duplicate_service_ids
      WHERE scheduling_service_prices.service_id = duplicate_service_ids.id
        AND scheduling_service_prices.active = TRUE
    SQL
  end
end
