class Integrations::Medelement::SyncCursor < ApplicationRecord
  self.table_name = 'medelement_sync_cursors'

  belongs_to :hook, class_name: 'Integrations::Hook'

  validates :name, presence: true, uniqueness: { scope: :hook_id }
end
