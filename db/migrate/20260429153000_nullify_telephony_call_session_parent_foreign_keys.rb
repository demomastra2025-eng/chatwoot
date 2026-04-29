class NullifyTelephonyCallSessionParentForeignKeys < ActiveRecord::Migration[7.0]
  def change
    remove_foreign_key :telephony_call_sessions, :conversations
    remove_foreign_key :telephony_call_sessions, :inboxes
    remove_foreign_key :telephony_call_sessions, :telephony_number_bindings, column: :number_binding_id

    add_foreign_key :telephony_call_sessions, :conversations, on_delete: :nullify
    add_foreign_key :telephony_call_sessions, :inboxes, on_delete: :nullify
    add_foreign_key :telephony_call_sessions, :telephony_number_bindings, column: :number_binding_id, on_delete: :nullify
  end
end
