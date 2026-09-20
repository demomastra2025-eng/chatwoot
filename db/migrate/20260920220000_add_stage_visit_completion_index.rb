class AddStageVisitCompletionIndex < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_crm_stage_visits_on_account_id_and_exited_at'.freeze

  def up
    return if completion_index_valid?

    remove_index :crm_stage_visits, name: INDEX_NAME, algorithm: :concurrently if completion_index_exists?
    add_index :crm_stage_visits,
              [:account_id, :exited_at],
              where: 'exited_at IS NOT NULL',
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    remove_index :crm_stage_visits, name: INDEX_NAME, algorithm: :concurrently if completion_index_exists?
  end

  private

  def completion_index_valid?
    index = completion_index
    return false unless index
    return false unless index.columns == %w[account_id exited_at]
    return false unless index.where.to_s.squish.delete('()') == 'exited_at IS NOT NULL'

    select_value(<<~SQL.squish) == true
      SELECT indisvalid
      FROM pg_index
      WHERE indexrelid = #{connection.quote(INDEX_NAME)}::regclass
    SQL
  end

  def completion_index_exists?
    completion_index.present?
  end

  def completion_index
    connection.indexes(:crm_stage_visits).find { |index| index.name == INDEX_NAME }
  end
end
