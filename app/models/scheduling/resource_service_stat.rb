# == Schema Information
#
# Table name: scheduling_resource_service_stats
#
#  id                  :bigint           not null, primary key
#  last_seen_at        :datetime
#  median_duration_min :integer
#  receptions_count    :integer          default(0), not null
#  source              :string           default("history"), not null
#  status              :string           default("auto"), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#  resource_id         :bigint           not null
#  service_id          :bigint           not null
#
# Indexes
#
#  idx_scheduling_resource_service_stats_on_resource_service  (resource_id,service_id) UNIQUE
#  idx_scheduling_resource_service_stats_on_service_status    (service_id,status)
#  index_scheduling_resource_service_stats_on_account_id      (account_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (resource_id => scheduling_resources.id)
#  fk_rails_...  (service_id => scheduling_services.id)
#

# A specialist-service pair read from the visit history (see Scheduling::ResourceServiceStatsAggregator): how many visits of the
# last months carried the service, the median length of those visits, and whether the pair counts.
#   auto      found by the aggregation and above its thresholds
#   confirmed set by staff: the pair counts whatever the history says
#   disabled  set by staff: the pair never counts
#   stale     was auto and fell below the thresholds (or vanished from the history); it counts again when the history recovers
class Scheduling::ResourceServiceStat < ApplicationRecord
  SOURCE_HISTORY = 'history'.freeze
  SOURCES = [SOURCE_HISTORY].freeze
  STATUS_AUTO = 'auto'.freeze
  STATUS_CONFIRMED = 'confirmed'.freeze
  STATUS_DISABLED = 'disabled'.freeze
  STATUS_STALE = 'stale'.freeze
  STATUSES = [STATUS_AUTO, STATUS_CONFIRMED, STATUS_DISABLED, STATUS_STALE].freeze
  # Set by staff: the aggregation never changes these.
  MANUAL_STATUSES = [STATUS_CONFIRMED, STATUS_DISABLED].freeze
  # The statuses that make a pair count for slot search and for the visit length.
  USABLE_STATUSES = [STATUS_AUTO, STATUS_CONFIRMED].freeze

  belongs_to :account
  belongs_to :resource, class_name: 'Scheduling::Resource', inverse_of: :service_stats
  belongs_to :service, class_name: 'Scheduling::Service', inverse_of: :resource_stats

  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :resource_id, uniqueness: { scope: :service_id }
  validates :receptions_count, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :median_duration_min,
            inclusion: { in: Scheduling::Constants::MIN_DURATION_MINUTES..Scheduling::Constants::MAX_DURATION_MINUTES },
            allow_nil: true
  validate :resource_and_service_belong_to_account

  scope :usable, -> { where(status: USABLE_STATUSES) }
  scope :ordered, -> { order(receptions_count: :desc, id: :asc) }

  def manual?
    MANUAL_STATUSES.include?(status)
  end

  private

  def resource_and_service_belong_to_account
    return if resource.blank? || service.blank?
    return if resource.account_id == account_id && service.account_id == account_id

    errors.add(:base, 'resource and service must belong to the account')
  end
end
