# == Schema Information
#
# Table name: copilot_threads
#
#  id           :bigint           not null, primary key
#  title        :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint           not null
#  assistant_id :integer
#  user_id      :bigint           not null
#
# Indexes
#
#  index_copilot_threads_on_account_id    (account_id)
#  index_copilot_threads_on_assistant_id  (assistant_id)
#  index_copilot_threads_on_user_id       (user_id)
#
class CopilotThread < ApplicationRecord
  belongs_to :user
  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant'
  has_many :copilot_messages, dependent: :destroy_async

  validates :title, presence: true
end
