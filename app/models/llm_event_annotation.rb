# == Schema Information
#
# Table name: llm_event_annotations
#
#  id           :bigint           not null, primary key
#  body         :text             not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint           not null
#  llm_event_id :bigint           not null
#  user_id      :bigint           not null
#
# Indexes
#
#  index_llm_event_annotations_on_account_event_created_at  (account_id,llm_event_id,created_at)
#  index_llm_event_annotations_on_account_id                (account_id)
#  index_llm_event_annotations_on_llm_event_id              (llm_event_id)
#  index_llm_event_annotations_on_user_id                   (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (llm_event_id => llm_events.id)
#  fk_rails_...  (user_id => users.id)
#

class LlmEventAnnotation < ApplicationRecord
  belongs_to :account
  belongs_to :llm_event
  belongs_to :user

  validates :body, presence: true, length: { maximum: 1_500 }

  scope :recent_first, -> { order(created_at: :desc) }
end
