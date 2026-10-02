class WhatsappUsageTrackingState < ApplicationRecord
  validates :tracking_started_at, presence: true

  def self.current_or_create!
    find_or_create_by!(id: 1) do |state|
      state.tracking_started_at = Time.current.utc
    end
  end
end
