# == Schema Information
#
# Table name: bulk_action_runs
#
#  id              :bigint           not null, primary key
#  action_name     :string           not null
#  completed_at    :datetime
#  error_message   :text
#  failed_count    :integer          default(0), not null
#  metadata        :jsonb            not null
#  processed_count :integer          default(0), not null
#  resource_type   :string           not null
#  started_at      :datetime
#  status          :integer          default("queued"), not null
#  total_count     :integer          default(0), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  user_id         :bigint           not null
#
# Indexes
#
#  idx_bulk_action_runs_on_account_resource_created  (account_id,resource_type,created_at)
#  idx_bulk_action_runs_on_account_user_created      (account_id,user_id,created_at)
#  index_bulk_action_runs_on_account_id              (account_id)
#  index_bulk_action_runs_on_user_id                 (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (user_id => users.id)
#
class BulkActionRun < ApplicationRecord
  belongs_to :account
  belongs_to :user

  enum status: {
    queued: 0,
    processing: 1,
    completed: 2,
    failed: 3
  }

  validates :resource_type, :action_name, presence: true
  validates :total_count, :processed_count, :failed_count, numericality: { greater_than_or_equal_to: 0 }

  def start!(total_count:)
    update!(
      status: :processing,
      total_count: total_count,
      started_at: Time.current,
      completed_at: nil,
      error_message: nil,
      processed_count: 0,
      failed_count: 0
    )
  end

  def advance!(processed_increment: 1, failed_increment: 0)
    self.class.where(id: id).update_all(
      [
        'processed_count = processed_count + ?, failed_count = failed_count + ?, updated_at = ?',
        processed_increment,
        failed_increment,
        Time.current
      ]
    )
    reload
  end

  def complete!
    reload
    if failed_count.positive?
      update!(
        status: :failed,
        completed_at: Time.current,
        processed_count: total_count,
        error_message: "#{failed_count} records failed"
      )
      return
    end

    update!(
      status: :completed,
      completed_at: Time.current,
      processed_count: total_count
    )
  end

  def fail!(message)
    update!(
      status: :failed,
      completed_at: Time.current,
      error_message: message
    )
  end

  def progress_percentage
    return 0 if total_count.to_i <= 0

    ((processed_count.to_f / total_count) * 100).round
  end

  def as_progress_json
    {
      id: id,
      resource_type: resource_type,
      action_name: action_name,
      status: status,
      total_count: total_count,
      processed_count: processed_count,
      failed_count: failed_count,
      progress_percentage: progress_percentage,
      error_message: error_message,
      metadata: metadata || {},
      started_at: started_at,
      completed_at: completed_at
    }
  end
end
