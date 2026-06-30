class ScopeSipProfileExtensionsToInbox < ActiveRecord::Migration[7.1]
  def up
    ensure_no_duplicate_extensions!

    remove_index :telephony_sip_profiles,
                 name: 'idx_tel_sip_profiles_account_inbox_user_ext',
                 if_exists: true

    add_index :telephony_sip_profiles,
              [:account_id, :inbox_id, :internal_extension],
              unique: true,
              name: 'idx_tel_sip_profiles_account_inbox_ext',
              if_not_exists: true
  end

  def down
    remove_index :telephony_sip_profiles,
                 name: 'idx_tel_sip_profiles_account_inbox_ext',
                 if_exists: true

    add_index :telephony_sip_profiles,
              [:account_id, :inbox_id, :user_id, :internal_extension],
              unique: true,
              name: 'idx_tel_sip_profiles_account_inbox_user_ext',
              if_not_exists: true
  end

  private

  def ensure_no_duplicate_extensions!
    duplicates = execute(<<~SQL.squish).to_a
      SELECT account_id, inbox_id, internal_extension, COUNT(*) AS profiles_count
      FROM telephony_sip_profiles
      WHERE internal_extension IS NOT NULL AND internal_extension <> ''
      GROUP BY account_id, inbox_id, internal_extension
      HAVING COUNT(*) > 1
      LIMIT 5
    SQL

    return if duplicates.blank?

    examples = duplicates.map do |row|
      "account=#{row['account_id']} inbox=#{row['inbox_id']} extension=#{row['internal_extension']} count=#{row['profiles_count']}"
    end.join('; ')

    raise ActiveRecord::MigrationError,
          "Duplicate telephony_sip_profiles internal_extension values must be resolved before adding the unique index: #{examples}"
  end
end
