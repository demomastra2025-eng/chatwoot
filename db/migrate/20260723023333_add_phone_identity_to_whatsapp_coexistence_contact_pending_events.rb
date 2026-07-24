class AddPhoneIdentityToWhatsappCoexistenceContactPendingEvents < ActiveRecord::Migration[7.1]
  RAW_PHONE_SQL = <<~SQL.squish.freeze
    regexp_replace(COALESCE(entry #>> '{contact,phone_number}', ''), '[^0-9]', '', 'g')
  SQL
  PHONE_IDENTITY_SQL = <<~SQL.squish.freeze
    CASE
      WHEN #{RAW_PHONE_SQL} LIKE '55%' AND char_length(#{RAW_PHONE_SQL}) <> 13
        THEN substring(#{RAW_PHONE_SQL} FROM 1 FOR 4) || '9' || substring(#{RAW_PHONE_SQL} FROM 5)
      WHEN #{RAW_PHONE_SQL} LIKE '54%'
        THEN regexp_replace(#{RAW_PHONE_SQL}, '^549', '54')
      ELSE NULLIF(#{RAW_PHONE_SQL}, '')
    END
  SQL
  INDEX_NAME = 'idx_wa_coex_pending_phone_identity'.freeze
  INDEX_COLUMNS = %i[account_id channel_id phone_identity id].freeze

  def up
    add_column :whatsapp_coexistence_contact_pending_events, :phone_identity, :string unless column_exists?(
      :whatsapp_coexistence_contact_pending_events, :phone_identity
    )
    backfill_phone_identities
    return if index_exists?(:whatsapp_coexistence_contact_pending_events, INDEX_COLUMNS, name: INDEX_NAME)

    add_index :whatsapp_coexistence_contact_pending_events,
              INDEX_COLUMNS,
              where: 'phone_identity IS NOT NULL',
              name: INDEX_NAME
  end

  def down
    remove_index :whatsapp_coexistence_contact_pending_events, name: INDEX_NAME if index_exists?(
      :whatsapp_coexistence_contact_pending_events, INDEX_COLUMNS, name: INDEX_NAME
    )
    remove_column :whatsapp_coexistence_contact_pending_events, :phone_identity if column_exists?(
      :whatsapp_coexistence_contact_pending_events, :phone_identity
    )
  end

  private

  def backfill_phone_identities
    execute <<~SQL.squish
      UPDATE whatsapp_coexistence_contact_pending_events
      SET phone_identity = #{PHONE_IDENTITY_SQL}
      WHERE phone_identity IS NULL
    SQL
  end
end
