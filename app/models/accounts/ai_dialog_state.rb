# frozen_string_literal: true

# Isolated from editable Contact JSON; serialized by the owning contact lock.
class Accounts::AiDialogState < ApplicationRecord
  self.table_name = 'account_ai_dialog_states'

  belongs_to :account
  belongs_to :contact
end
