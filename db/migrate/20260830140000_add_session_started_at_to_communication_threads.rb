class AddSessionStartedAtToCommunicationThreads < ActiveRecord::Migration[7.1]
  def change
    add_column :communication_threads, :session_started_at, :datetime
  end
end
