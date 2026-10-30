class CreateContactPhones < ActiveRecord::Migration[7.1]
  SHARED_PHONES_BACKFILL_SQL = <<~SQL.squish.freeze
    INSERT INTO contact_phones (account_id, contact_id, phone_number, "primary", shared, owner_contact_id, created_at, updated_at)
    SELECT
      c.account_id,
      c.id,
      COALESCE(NULLIF(c.custom_attributes ->> 'medelement_shared_phone_number', ''), owner_c.phone_number),
      FALSE,
      TRUE,
      owner_c.id,
      NOW(),
      NOW()
    FROM contacts c
    LEFT JOIN contacts owner_c
      ON owner_c.account_id = c.account_id
     AND owner_c.id = CASE
       WHEN COALESCE(c.custom_attributes ->> 'medelement_shared_phone_owner_contact_id', '') ~ '^[0-9]+$'
       THEN (c.custom_attributes ->> 'medelement_shared_phone_owner_contact_id')::bigint
       ELSE NULL
     END
    WHERE COALESCE(NULLIF(c.custom_attributes ->> 'medelement_shared_phone_number', ''), owner_c.phone_number, '') ~ '^[+][1-9][0-9]{1,14}$'
      AND jsonb_typeof(c.custom_attributes -> 'secondary_phones') = 'array'
      AND (c.custom_attributes -> 'secondary_phones') @> to_jsonb(
        COALESCE(NULLIF(c.custom_attributes ->> 'medelement_shared_phone_number', ''), owner_c.phone_number)
      )
    ON CONFLICT DO NOTHING
  SQL

  def up
    create_contact_phones_table!
    add_contact_phones_indexes!
    backfill_primary_phones!
    backfill_shared_phones!
  end

  def down
    drop_table :contact_phones
  end

  private

  def create_contact_phones_table!
    create_table :contact_phones do |t|
      t.bigint :account_id, null: false
      t.bigint :contact_id, null: false
      t.string :phone_number, null: false
      t.boolean :primary, null: false, default: false
      t.boolean :shared, null: false, default: false
      t.bigint :owner_contact_id
      t.string :label
      t.timestamps
    end

    add_foreign_key :contact_phones, :contacts, column: :contact_id, on_delete: :cascade
    add_foreign_key :contact_phones, :contacts, column: :owner_contact_id, on_delete: :nullify
  end

  def add_contact_phones_indexes!
    add_index :contact_phones, [:account_id, :phone_number],
              unique: true, where: 'shared = false', name: 'idx_contact_phones_unique_owner_per_account'
    add_index :contact_phones, [:account_id, :contact_id, :phone_number],
              unique: true, name: 'idx_contact_phones_unique_contact_phone'
    add_index :contact_phones, :contact_id, name: 'index_contact_phones_on_contact_id'
    add_index :contact_phones, :owner_contact_id,
              where: 'owner_contact_id IS NOT NULL', name: 'index_contact_phones_on_owner_contact_id'
    add_index :contact_phones, [:account_id, :phone_number], name: 'index_contact_phones_on_account_and_phone'
    add_expression_indexes!
  end

  def add_expression_indexes!
    execute <<~SQL.squish
      CREATE INDEX index_contact_phones_on_account_id_and_phone_national
        ON contact_phones
        USING btree (account_id, right(regexp_replace(phone_number, '[^0-9]'::text, ''::text, 'g'::text), 10))
    SQL

    execute <<~SQL.squish
      CREATE INDEX index_contact_phones_on_phone_digits_trgm
        ON contact_phones
        USING gin (regexp_replace(phone_number, '[^0-9]'::text, ''::text, 'g'::text) gin_trgm_ops)
    SQL
  end

  def backfill_primary_phones!
    execute <<~SQL.squish
      INSERT INTO contact_phones (account_id, contact_id, phone_number, "primary", shared, created_at, updated_at)
      SELECT account_id, id, phone_number, TRUE, FALSE, NOW(), NOW()
      FROM contacts
      WHERE phone_number IS NOT NULL
        AND phone_number <> ''
      ON CONFLICT DO NOTHING
    SQL
  end

  def backfill_shared_phones!
    execute SHARED_PHONES_BACKFILL_SQL
  end
end
