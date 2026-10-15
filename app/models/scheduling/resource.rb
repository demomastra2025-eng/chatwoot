# == Schema Information
#
# Table name: scheduling_resources
#
#  id                   :bigint           not null, primary key
#  active               :boolean          default(TRUE), not null
#  color                :string
#  compensation_percent :integer          default(0), not null
#  compensation_type    :string           default("percent"), not null
#  compensation_value   :integer          default(0), not null
#  custom_attributes    :jsonb            not null
#  description          :text
#  name                 :string           not null
#  photo_url            :string
#  slot_duration_min    :integer          default(30), not null
#  specialty            :string
#  timezone             :string           default("Asia/Almaty"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint           not null
#  user_id              :bigint
#
# Indexes
#
#  idx_scheduling_resources_account_medelement_specialist_code  (account_id, ((custom_attributes ->> 'medelement_specialist_code'::text))) UNIQUE WHERE ((custom_attributes ->> 'medelement_specialist_code'::text) IS NOT NULL)
#  idx_scheduling_resources_on_account_active_name              (account_id,active,name)
#  index_scheduling_resources_on_account_id                     (account_id)
#  index_scheduling_resources_on_user_id                        (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (user_id => users.id)
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

  attribute :inherit_working_hours_from_account, :boolean, default: true
  after_create :apply_workspace_working_hours!, if: :inherit_working_hours_from_account?

  validates :name, :timezone, presence: true
  validates :slot_duration_min,
            inclusion: {
              in: Scheduling::Constants::MIN_DURATION_MINUTES..Scheduling::Constants::MAX_DURATION_MINUTES
            }
  validate :valid_timezone
  validate :user_belongs_to_account

  scope :ordered, -> { order(:name, :id) }
  scope :active, -> { where(active: true) }
  scope :not_deleted_from_scheduling,
        -> { where.not('custom_attributes @> ?', { DELETED_FROM_SCHEDULING_KEY => true }.to_json) }
  scope :available_for_scheduling, -> { active.not_deleted_from_scheduling }

  def deleted_from_scheduling?
    !!ActiveModel::Type::Boolean.new.cast(custom_attributes[DELETED_FROM_SCHEDULING_KEY])
  end

  def archive_from_scheduling!
    update!(
      active: false,
      custom_attributes: custom_attributes.to_h.merge(DELETED_FROM_SCHEDULING_KEY => true)
    )
  end

  def apply_workspace_working_hours!
    return unless inherit_working_hours_from_account?

    with_lock do
      update!(timezone: account.workspace_working_hours_timezone) if timezone != account.workspace_working_hours_timezone
      workspace_schedule_days.each { |day| sync_workspace_day!(day) }
      break_rules.find_each { |rule| rule.update!(active: false) }
      account.workspace_break_schedule.each { |entry| sync_workspace_break!(entry) }
    end
  end

  def sync_workspace_schedule!
    apply_workspace_working_hours! if inherit_working_hours_from_account?
  end

  def use_personal_working_hours!
    update!(inherit_working_hours_from_account: false)
    work_rules.find_each { |rule| rule.update!(active: false) }
    break_rules.find_each { |rule| rule.update!(active: false) }
  end

  private

  def workspace_schedule_days
    return account.workspace_working_hours_schedule if account.workspace_working_hours_configured?

    (0..6).map { |weekday| { 'day_of_week' => weekday, 'closed_all_day' => false, 'open_all_day' => true } }
  end

  def sync_workspace_day!(day)
    closed = ActiveModel::Type::Boolean.new.cast(day['closed_all_day'])
    full_day = closed || ActiveModel::Type::Boolean.new.cast(day['open_all_day'])
    attributes = {
      active: !closed,
      start_minute: full_day ? 0 : (day['open_hour'].to_i * 60) + day['open_minutes'].to_i,
      end_minute: full_day ? 1440 : (day['close_hour'].to_i * 60) + day['close_minutes'].to_i
    }
    work_rules.find_or_initialize_by(weekday: day['day_of_week']).update!(**attributes, account: account)
  end

  def sync_workspace_break!(entry)
    start_minute = minute_for_clock(entry['start_time'])
    end_minute = minute_for_clock(entry['end_time'])
    entry['days'].each do |weekday|
      rule = break_rules.find_or_initialize_by(weekday: weekday, start_minute: start_minute, end_minute: end_minute)
      rule.update!(active: true, account: account, title: entry['title'])
    end
  end

  def minute_for_clock(value)
    hour, minute = value.split(':').map(&:to_i)
    (hour * 60) + minute
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
