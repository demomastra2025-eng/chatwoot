# frozen_string_literal: true

class RemoveTelegramNotificationVerificationCodes < ActiveRecord::Migration[7.1]
  CODE_DIGEST_INDEX = 'index_tg_notification_bindings_on_code_digest'
  TABLE_NAME = :telegram_notification_bindings

  def up
    remove_index TABLE_NAME, name: CODE_DIGEST_INDEX if index_exists?(TABLE_NAME, :verification_code_digest, name: CODE_DIGEST_INDEX)

    remove_verification_column(:verification_code_digest)
    remove_verification_column(:verification_code_generated_at)
    remove_verification_column(:verification_code_expires_at)
  end

  def down
    add_verification_column(:verification_code_digest, :string)
    add_verification_column(:verification_code_generated_at, :datetime)
    add_verification_column(:verification_code_expires_at, :datetime)

    return if index_exists?(TABLE_NAME, :verification_code_digest, name: CODE_DIGEST_INDEX)

    add_index TABLE_NAME,
              :verification_code_digest,
              unique: true,
              where: 'verification_code_digest IS NOT NULL',
              name: CODE_DIGEST_INDEX
  end

  private

  def remove_verification_column(column)
    remove_column TABLE_NAME, column if column_exists?(TABLE_NAME, column)
  end

  def add_verification_column(column, type)
    add_column TABLE_NAME, column, type unless column_exists?(TABLE_NAME, column)
  end
end
