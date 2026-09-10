class AddAccessRoleSupportingIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  TABLE = :custom_roles
  INDEX_NAME = 'index_custom_roles_on_account_and_id'.freeze
  INDEX_COLUMNS = %w[account_id id].freeze

  def up
    existing_index = connection.indexes(TABLE).find { |index| index.name == INDEX_NAME }
    if existing_index
      validate_index!(existing_index)
      return if existing_index.valid

      remove_index TABLE, name: INDEX_NAME, algorithm: :concurrently
    end

    add_index TABLE,
              INDEX_COLUMNS,
              unique: true,
              algorithm: :concurrently,
              name: INDEX_NAME
  end

  def down
    return unless connection.indexes(TABLE).any? { |index| index.name == INDEX_NAME }

    remove_index TABLE, name: INDEX_NAME, algorithm: :concurrently
  end

  private

  def validate_index!(index)
    compatible = index.unique &&
                 index.columns == INDEX_COLUMNS &&
                 index.where.nil? &&
                 index.using == :btree &&
                 index.type.nil? &&
                 index.opclasses.empty?
    return if compatible

    raise ActiveRecord::MigrationError, "Existing #{INDEX_NAME} has an incompatible definition"
  end
end
