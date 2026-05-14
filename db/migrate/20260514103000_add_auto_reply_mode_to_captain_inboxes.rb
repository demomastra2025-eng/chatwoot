class AddAutoReplyModeToCaptainInboxes < ActiveRecord::Migration[7.0]
  def change
    add_column :captain_inboxes, :auto_reply_mode, :string, null: false, default: 'always'
  end
end
