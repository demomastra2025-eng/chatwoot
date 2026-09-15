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
#  inherit_working_hours_from_account :boolean default(FALSE), not null
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
  belongs_to :team, optional: true

  has_many :appointments, class_name: 'Scheduling::Appointment', dependent: :destroy_async, inverse_of: :resource
  has_many :break_rules, class_name: 'Scheduling::BreakRule', dependent: :destroy_async, inverse_of: :resource
  has_many :service_prices, class_name: 'Scheduling::ServicePrice', dependent: :destroy_async, inverse_of: :resource
  has_many :time_offs, class_name: 'Scheduling::TimeOff', dependent: :destroy_async, inverse_of: :resource
  has_many :work_rules, class_name: 'Scheduling::WorkRule', dependent: :destroy_async, inverse_of: :resource
  has_many :workday_overrides, class_name: 'Scheduling::WorkdayOverride', dependent: :destroy_async, inverse_of: :resource

  before_validation :sync_timezone_from_account
  after_update_commit :invalidate_appointment_scope, if: :saved_change_to_scope_owner?

  validates :name, :timezone, presence: true
  validates :slot_duration_min, inclusion: { in: 5..720 }
  validates :compensation_type, inclusion: { in: Scheduling::Constants::COMPENSATION_TYPES }
  validates :compensation_value, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :compensation_percent, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validate :valid_timezone
  validate :compensation_percent_within_range
  validate :combined_compensation_percent_within_range
  validate :user_belongs_to_account
  validate :team_belongs_to_account

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
    with_lock do
      reload
      return unless inherit_working_hours_from_account?

      replace_with_workspace_schedule!
    end
  end

  def sync_workspace_schedule!
    with_lock do
      reload
      if inherit_working_hours_from_account?
        replace_with_workspace_schedule!
      else
        update!(timezone: account.workspace_working_hours_timezone)
      end
    end
  end

  def replace_schedule!(inherit:, work_rules:, break_rules:, expected_revision:)
    with_lock do
      reload
      current_revision = Scheduling::ResourceScheduleRevision.generate(self)
      if current_revision != expected_revision
        raise Scheduling::Error.new(
          code: 'SCHEDULE_VERSION_CONFLICT',
          message: 'The specialist schedule was changed after it was opened',
          status: :conflict,
          details: { current_schedule_revision: current_revision }
        )
      end

      update!(inherit_working_hours_from_account: inherit)
      inherit ? replace_with_workspace_schedule! : replace_with_personal_schedule!(work_rules, break_rules)
      block_given? ? yield(self) : self
    end
  end

  private

  def saved_change_to_scope_owner?
    saved_change_to_user_id? || saved_change_to_team_id?
  end

  def invalidate_appointment_scope
    Scheduling::ScopeInvalidation.dispatch(account)
  end

  def replace_with_personal_schedule!(work_rules, break_rules)
    self.work_rules.destroy_all
    self.break_rules.destroy_all
    work_rules.each { |rule| self.work_rules.create!(rule) }
    break_rules.each { |rule| self.break_rules.create!(rule) }
  end

  def replace_with_workspace_schedule!
    inherited_rules = account.workspace_working_hours_schedule.map { |day| inherited_work_rule(day) }

    update!(timezone: account.workspace_working_hours_timezone)
    work_rules.destroy_all
    break_rules.destroy_all
    inherited_rules.each { |rule| work_rules.create!(account: account, **rule) }
    inherited_break_rules.each { |rule| break_rules.create!(account: account, **rule) }
  end

  def sync_timezone_from_account
    self.timezone = account.workspace_working_hours_timezone if account.present?
  end

  def inherited_break_rules
    account.workspace_break_schedule.flat_map do |entry|
      entry['days'].map do |weekday|
        {
          active: true,
          end_minute: minute_for_time(entry['end_time']),
          start_minute: minute_for_time(entry['start_time']),
          title: entry['title'].presence,
          weekday: weekday
        }
      end
    end
  end

  def inherited_work_rule(day)
    open_all_day = ActiveModel::Type::Boolean.new.cast(day['open_all_day'])
    closed_all_day = ActiveModel::Type::Boolean.new.cast(day['closed_all_day'])
    full_day = open_all_day || closed_all_day

    {
      active: !closed_all_day,
      end_minute: full_day ? 1440 : minutes_for(day, 'close'),
      start_minute: full_day ? 0 : minutes_for(day, 'open'),
      weekday: day['day_of_week']
    }
  end

  def minutes_for(day, prefix)
    (day["#{prefix}_hour"].to_i * 60) + day["#{prefix}_minutes"].to_i
  end

  def minute_for_time(value)
    hour, minute = value.split(':').map(&:to_i)
    (hour * 60) + minute
  end

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

  def team_belongs_to_account
    return if team_id.blank? || account.blank?
    return if team&.account_id == account_id

    errors.add(:team_id, 'must belong to the current account')
  end
end
