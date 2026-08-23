class Whatsapp::PendingMessageMutation < ApplicationRecord
  self.table_name = 'whatsapp_pending_message_mutations'

  MUTATION_TYPES = %w[reaction edit revoke].freeze

  belongs_to :account
  belongs_to :inbox

  validates :event_id, :target_source_id, :mutation_type, presence: true
  validates :mutation_type, inclusion: { in: MUTATION_TYPES }
  validate :inbox_belongs_to_account

  private

  def inbox_belongs_to_account
    return if inbox.blank? || account_id == inbox.account_id

    errors.add(:inbox, 'must belong to the same account')
  end
end
