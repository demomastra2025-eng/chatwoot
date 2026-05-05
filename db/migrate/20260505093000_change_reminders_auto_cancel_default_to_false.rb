# frozen_string_literal: true

class ChangeRemindersAutoCancelDefaultToFalse < ActiveRecord::Migration[7.1]
  def change
    change_column_default :reminders, :auto_cancel_on_incoming, from: true, to: false
  end
end
