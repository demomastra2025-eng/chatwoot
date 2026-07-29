# The reversible data migration keeps its SQL CTEs together so the ranked
# service/price policy can be audited as one unit.
# rubocop:disable Metrics/ClassLength, Metrics/MethodLength
class AddMedelementServiceDedupeIndex < ActiveRecord::Migration[7.1]
  INDEX_NAME = 'idx_scheduling_services_account_medelement_code_unique'.freeze
  CODE_KEY = 'medelement_nomenclature_code'.freeze
  DUPLICATE_CODE_KEY = 'medelement_duplicate_nomenclature_code'.freeze
  DUPLICATE_OF_KEY = 'medelement_duplicate_of_service_id'.freeze
  DUPLICATE_WAS_ACTIVE_KEY = 'medelement_duplicate_was_active'.freeze
  MIGRATED_PRICE_IDS_KEY = 'medelement_migrated_price_ids'.freeze
  DEACTIVATED_PRICE_IDS_KEY = 'medelement_deactivated_price_ids'.freeze
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
  RANKED_PRICES_SQL = <<~SQL.squish.freeze
    SELECT scheduling_service_prices.id,
           scheduling_service_prices.service_id AS original_service_id,
           ranked_services.keeper_id,
           scheduling_service_prices.active,
           BOOL_OR(scheduling_service_prices.service_id = ranked_services.keeper_id) OVER (
             PARTITION BY ranked_services.keeper_id, scheduling_service_prices.resource_id
           ) AS keeper_has_price,
           ROW_NUMBER() OVER (
             PARTITION BY ranked_services.keeper_id, scheduling_service_prices.resource_id
             ORDER BY (scheduling_service_prices.service_id = ranked_services.keeper_id) DESC,
                      scheduling_service_prices.active DESC,
                      scheduling_service_prices.updated_at DESC,
                      scheduling_service_prices.id ASC
           ) AS price_rank
    FROM scheduling_service_prices
    INNER JOIN (#{RANKED_SERVICES_SQL}) ranked_services
      ON ranked_services.id = scheduling_service_prices.service_id
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
    restore_duplicate_prices!
    restore_duplicate_services!
  end

  private

  def quarantine_duplicate_services!
    annotate_duplicate_services!
    migrate_non_conflicting_prices!
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
              '#{DUPLICATE_OF_KEY}', ranked_services.keeper_id,
              '#{DUPLICATE_WAS_ACTIVE_KEY}', scheduling_services.active
            ),
          updated_at = CURRENT_TIMESTAMP
      FROM ranked_services
      WHERE scheduling_services.id = ranked_services.id
        AND ranked_services.duplicate_rank > 1
    SQL
  end

  def annotate_duplicate_services!
    execute <<~SQL.squish
      WITH ranked_prices AS (
        #{RANKED_PRICES_SQL}
      )
      UPDATE scheduling_services
      SET custom_attributes = scheduling_services.custom_attributes || jsonb_build_object(
            '#{MIGRATED_PRICE_IDS_KEY}', COALESCE((
              SELECT jsonb_agg(ranked_prices.id ORDER BY ranked_prices.id)
              FROM ranked_prices
              WHERE ranked_prices.original_service_id = scheduling_services.id
                AND ranked_prices.price_rank = 1
                AND ranked_prices.keeper_has_price = FALSE
            ), '[]'::jsonb),
            '#{DEACTIVATED_PRICE_IDS_KEY}', COALESCE((
              SELECT jsonb_agg(ranked_prices.id ORDER BY ranked_prices.id)
              FROM ranked_prices
              WHERE ranked_prices.original_service_id = scheduling_services.id
                AND ranked_prices.active = TRUE
                AND NOT (ranked_prices.price_rank = 1 AND ranked_prices.keeper_has_price = FALSE)
            ), '[]'::jsonb)
          )
      FROM (#{RANKED_SERVICES_SQL}) ranked_services
      WHERE scheduling_services.id = ranked_services.id
        AND ranked_services.duplicate_rank > 1
    SQL
  end

  def migrate_non_conflicting_prices!
    execute <<~SQL.squish
      WITH ranked_prices AS (
        #{RANKED_PRICES_SQL}
      )
      UPDATE scheduling_service_prices
      SET service_id = ranked_prices.keeper_id,
          updated_at = CURRENT_TIMESTAMP
      FROM ranked_prices
      WHERE scheduling_service_prices.id = ranked_prices.id
        AND ranked_prices.original_service_id <> ranked_prices.keeper_id
        AND ranked_prices.price_rank = 1
        AND ranked_prices.keeper_has_price = FALSE
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

  def restore_duplicate_prices!
    execute <<~SQL.squish
      UPDATE scheduling_service_prices
      SET service_id = scheduling_services.id,
          updated_at = CURRENT_TIMESTAMP
      FROM scheduling_services,
           LATERAL jsonb_array_elements_text(
             COALESCE(scheduling_services.custom_attributes -> '#{MIGRATED_PRICE_IDS_KEY}', '[]'::jsonb)
           ) migrated_price_id
      WHERE scheduling_service_prices.id = migrated_price_id::bigint
        AND scheduling_services.custom_attributes ? '#{DUPLICATE_OF_KEY}'
    SQL

    execute <<~SQL.squish
      UPDATE scheduling_service_prices
      SET active = TRUE,
          updated_at = CURRENT_TIMESTAMP
      FROM scheduling_services,
           LATERAL jsonb_array_elements_text(
             COALESCE(scheduling_services.custom_attributes -> '#{DEACTIVATED_PRICE_IDS_KEY}', '[]'::jsonb)
           ) deactivated_price_id
      WHERE scheduling_service_prices.id = deactivated_price_id::bigint
        AND scheduling_services.custom_attributes ? '#{DUPLICATE_OF_KEY}'
    SQL
  end

  def restore_duplicate_services!
    execute <<~SQL.squish
      UPDATE scheduling_services
      SET active = COALESCE((scheduling_services.custom_attributes ->> '#{DUPLICATE_WAS_ACTIVE_KEY}')::boolean, FALSE),
          custom_attributes = (
            scheduling_services.custom_attributes
              - '#{DUPLICATE_CODE_KEY}'
              - '#{DUPLICATE_OF_KEY}'
              - '#{DUPLICATE_WAS_ACTIVE_KEY}'
              - '#{MIGRATED_PRICE_IDS_KEY}'
              - '#{DEACTIVATED_PRICE_IDS_KEY}'
          ) || jsonb_build_object(
            '#{CODE_KEY}', scheduling_services.custom_attributes ->> '#{DUPLICATE_CODE_KEY}'
          ),
          updated_at = CURRENT_TIMESTAMP
      WHERE scheduling_services.custom_attributes ? '#{DUPLICATE_OF_KEY}'
    SQL
  end
end
# rubocop:enable Metrics/ClassLength, Metrics/MethodLength
