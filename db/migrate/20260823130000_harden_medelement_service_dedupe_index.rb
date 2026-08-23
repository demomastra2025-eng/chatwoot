class HardenMedelementServiceDedupeIndex < ActiveRecord::Migration[7.1]
  INDEX_NAME = 'idx_scheduling_services_account_medelement_code_unique'.freeze
  CODE_KEY = 'medelement_nomenclature_code'.freeze
  FIXED_PREDICATE = "NULLIF(BTRIM(custom_attributes ->> '#{CODE_KEY}'), '') IS NOT NULL".freeze
  LEGACY_PREDICATE = "custom_attributes ->> '#{CODE_KEY}' IS NOT NULL".freeze

  def up
    return if fixed_index?

    replace_index!(FIXED_PREDICATE)
  end

  def down
    replace_index!(LEGACY_PREDICATE)
  end

  private

  def fixed_index?
    predicate = medelement_index&.where.to_s.upcase
    predicate.include?('NULLIF') && predicate.include?('BTRIM')
  end

  def medelement_index
    connection.indexes(:scheduling_services).find { |index| index.name == INDEX_NAME }
  end

  def replace_index!(predicate)
    remove_index :scheduling_services, name: INDEX_NAME if medelement_index
    add_index :scheduling_services,
              "account_id, (custom_attributes ->> '#{CODE_KEY}')",
              unique: true,
              where: predicate,
              name: INDEX_NAME
  end
end
