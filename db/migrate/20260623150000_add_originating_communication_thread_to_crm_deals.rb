class AddOriginatingCommunicationThreadToCrmDeals < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  THREAD_INDEX_NAME = 'index_crm_deals_on_originating_communication_thread_id'.freeze
  ACCOUNT_THREAD_INDEX_NAME = 'index_crm_deals_on_account_originating_thread'.freeze

  def up
    add_originating_thread_column
    add_originating_thread_indexes
    add_originating_thread_foreign_key
  end

  def down
    remove_originating_thread_foreign_key
    remove_originating_thread_indexes
    remove_column :crm_deals, :originating_communication_thread_id if column_exists?(:crm_deals, :originating_communication_thread_id)
  end

  private

  def add_originating_thread_column
    return if column_exists?(:crm_deals, :originating_communication_thread_id)

    add_reference :crm_deals,
                  :originating_communication_thread,
                  foreign_key: false,
                  index: false
  end

  def add_originating_thread_indexes
    unless index_exists?(:crm_deals, :originating_communication_thread_id, name: THREAD_INDEX_NAME)
      add_index :crm_deals,
                :originating_communication_thread_id,
                name: THREAD_INDEX_NAME,
                algorithm: :concurrently
    end

    return if account_thread_index_exists?

    add_index :crm_deals,
              [:account_id, :originating_communication_thread_id],
              name: ACCOUNT_THREAD_INDEX_NAME,
              algorithm: :concurrently
  end

  def add_originating_thread_foreign_key
    return if foreign_key_exists?(:crm_deals, :communication_threads, column: :originating_communication_thread_id)

    add_foreign_key :crm_deals,
                    :communication_threads,
                    column: :originating_communication_thread_id,
                    validate: false
    validate_foreign_key :crm_deals, :communication_threads, column: :originating_communication_thread_id
  end

  def remove_originating_thread_foreign_key
    return unless foreign_key_exists?(:crm_deals, column: :originating_communication_thread_id)

    remove_foreign_key :crm_deals, column: :originating_communication_thread_id
  end

  def remove_originating_thread_indexes
    remove_index :crm_deals, name: ACCOUNT_THREAD_INDEX_NAME, algorithm: :concurrently if index_exists?(:crm_deals, name: ACCOUNT_THREAD_INDEX_NAME)
    remove_index :crm_deals, name: THREAD_INDEX_NAME, algorithm: :concurrently if index_exists?(:crm_deals, name: THREAD_INDEX_NAME)
  end

  def account_thread_index_exists?
    index_exists?(:crm_deals, [:account_id, :originating_communication_thread_id], name: ACCOUNT_THREAD_INDEX_NAME)
  end
end
