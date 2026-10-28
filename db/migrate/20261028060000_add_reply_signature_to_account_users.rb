class AddReplySignatureToAccountUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :account_users, :reply_signature, :string, limit: 200
  end
end
