# == Schema Information
#
# Table name: scheduling_resources
#
#  id                 :bigint           not null, primary key
#  active             :boolean          default(TRUE), not null
#  color              :string
#  compensation_type  :string           default("percent"), not null
#  compensation_value :integer          default(0), not null
#  compensation_percent :integer         default(0), not null
#  custom_attributes  :jsonb            not null
#  description        :text
#  name               :string           not null
#  photo_url          :string
#  slot_duration_min  :integer          default(30), not null
#  specialty          :string
#  timezone           :string           default("Asia/Almaty"), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :bigint           not null
#  user_id            :bigint
#

class Scheduling::Resource < ApplicationRecord
  DELETED_FROM_SCHEDULING_KEY = 'deleted_from_scheduling'.freeze

  belongs_to :account
  belongs_to :user, optional: true

  has_many :appointments, class_name: 'Scheduling::Appointment', dependent: :destroy_async, inverse_of: :resource
  has_many :break_rules, class_name: 'Scheduling::BreakRule', dependent: :destroy_async, inverse_of: :resource
  has_many :service_prices, class_name: 'Scheduling::ServicePrice', dependent: :destroy_async, inverse_of: :resource
  has_many :time_offs, class_name: 'Scheduling::TimeOff', dependent: :destroy_async, inverse_of: :resource
  has_many :work_rules, class_name: 'Scheduling::WorkRule', dependent: :destroy_async, inverse_of: :resource
  has_many :workday_overrides, class_name: 'Scheduling::WorkdayOverride', dependent: :destroy_async, inverse_of: :resource

  validates :name, :timezone, presence: true
  validates :slot_duration_min, inclusion: { in: 5..720 }
  validates :compensation_type, inclusion: { in: Scheduling::Constants::COMPENSATION_TYPES }
  validates :compensation_value, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :compensation_percent, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validate :valid_timezone
  validate :compensation_percent_within_range
  validate :combined_compensation_percent_within_range
  validate :user_belongs_to_account

  scope :ordered, -> { order(:name, :id) }
  scope :active, -> { where(active: true) }
  scope :not_deleted_from_scheduling,
        -> { where.not("custom_attributes @> ?", { DELETED_FROM_SCHEDULING_KEY => true }.to_json) }
  scope :available_for_scheduling, -> { active.not_deleted_from_scheduling }

  def deleted_from_scheduling?
    ActiveModel::Type::Boolean.new.cast(custom_attributes[DELETED_FROM_SCHEDULING_KEY])
  end

  def archive_from_scheduling!
    update!(
      active: false,
      custom_attributes: custom_attributes.to_h.merge(DELETED_FROM_SCHEDULING_KEY => true)
    )
  end

  private

  def compensation_percent_within_range
    return unless compensation_type == 'percent'
    return if compensation_value.to_i.between?(0, 100)

    errors.add(:compensation_value, 'must be between 0 and 100 for percent compensation')
  end

  def combined_compensation_percent_within_range
    return unless compensation_type == 'fixed_plus_percent'
    return if compensation_percent.to_i.between?(0, 100)

    errors.add(:compensation_percent, 'must be between 0 and 100 for fixed plus percent compensation')
  end

  def valid_timezone
    return if ActiveSupport::TimeZone[timezone].present?

    errors.add(:timezone, 'must be a valid timezone')
  end

  def user_belongs_to_account
    return if user_id.blank? || account.blank?
    return if account.users.exists?(id: user_id)

    errors.add(:user_id, 'must belong to the current account')
  end
end
