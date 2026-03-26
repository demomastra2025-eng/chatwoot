# == Schema Information
#
# Table name: crm_events
#
#  id             :bigint           not null, primary key
#  event_type     :string           not null
#  eventable_type :string           not null
#  meta           :jsonb            not null
#  created_at     :datetime         not null
#  account_id     :bigint           not null
#  actor_id       :bigint
#  eventable_id   :bigint           not null
#
# Indexes
#
#  index_crm_events_on_account_eventable_created_at  (account_id,eventable_type,eventable_id,created_at)
#  index_crm_events_on_account_id                    (account_id)
#  index_crm_events_on_actor_id                      (actor_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (actor_id => users.id)
#
class Crm::Event < ApplicationRecord
  self.table_name = 'crm_events'

  belongs_to :account, class_name: '::Account'
  belongs_to :eventable, polymorphic: true
  belongs_to :actor, class_name: '::User', optional: true

  validates :event_type, presence: true

  before_validation :prepare_meta

  scope :ordered, -> { order(created_at: :desc, id: :desc) }

  private

  def prepare_meta
    self.meta = {} if meta.blank?
  end
end
