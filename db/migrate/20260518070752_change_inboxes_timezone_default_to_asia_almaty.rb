class ChangeInboxesTimezoneDefaultToAsiaAlmaty < ActiveRecord::Migration[7.1]
  def change
    change_column_default :inboxes, :timezone, from: 'UTC', to: 'Asia/Almaty'
  end
end
