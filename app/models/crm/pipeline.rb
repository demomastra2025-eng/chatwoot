# == Schema Information
#
# Table name: crm_pipelines
#
#  id                                  :bigint           not null, primary key
#  active                              :boolean          default(TRUE), not null
#  auto_create_deal_on_channel_contact :boolean          default(FALSE), not null
#  code                                :string           not null
#  default                             :boolean          default(FALSE), not null
#  name                                :string           not null
#  position                            :integer          default(0), not null
#  created_at                          :datetime         not null
#  updated_at                          :datetime         not null
#  account_id                          :bigint           not null
#
# Indexes
#
#  index_crm_pipelines_on_account_default_active  (account_id) UNIQUE WHERE (("default" = true) AND (active = true))
#  index_crm_pipelines_on_account_id              (account_id)
#  index_crm_pipelines_on_account_id_and_code     (account_id,code) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class Crm::Pipeline < ApplicationRecord
  self.table_name = 'crm_pipelines'

  belongs_to :account, class_name: '::Account'
  has_many :stages, -> { ordered }, class_name: '::Crm::Stage', dependent: :destroy, inverse_of: :pipeline
  has_many :deals, class_name: '::Crm::Deal', inverse_of: :pipeline # rubocop:disable Rails/HasManyOrHasOneDependent
  has_many :stage_visits, class_name: '::Crm::StageVisit', dependent: :nullify, inverse_of: :pipeline

  validates :name, presence: true
  validates :code, presence: true, uniqueness: { scope: :account_id }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :validate_appointment_automation

  scope :ordered, -> { order(:position, :id) }
  scope :active, -> { where(active: true) }

  before_validation :normalize_name
  before_validation :normalize_code
  before_validation :assign_position, on: :create
  before_validation :disable_default_when_inactive
  before_save :clear_other_defaults, if: :reassigning_default?
  before_save :prepare_appointment_automation_sources, if: :will_save_change_to_appointment_automation?
  after_update_commit :refresh_appointment_automation, if: :saved_change_to_appointment_automation?
  before_destroy :ensure_stage_visits_detachable, prepend: true

  private

  def validate_appointment_automation
    return unless will_save_change_to_appointment_automation?

    Crm::Appointments::Configuration.validate(self).each { |error| errors.add(:appointment_automation, error) }
  end

  def prepare_appointment_automation_sources
    previous = appointment_automation_in_database.to_h
    self.appointment_automation = appointment_automation.to_h.deep_stringify_keys
    Crm::Appointments::Configuration::SOURCE_KEYS.each do |key|
      next unless appointment_automation[key] == true

      appointment_automation["#{key}_enabled_at"] = previous["#{key}_enabled_at"].presence || Time.current.iso8601(6) if previous[key] == true
      appointment_automation["#{key}_enabled_at"] = Time.current.iso8601(6) unless previous[key] == true
      account.crm_pipelines.where.not(id: id).where("appointment_automation ->> ? = 'true'", key).find_each do |other|
        other.update!(appointment_automation: other.appointment_automation.merge(key => false))
      end
    end
  end

  def refresh_appointment_automation
    Crm::Appointments::RefreshPipelineJob.perform_later(account_id, id)
  rescue StandardError => e
    Rails.logger.warn("CRM appointment refresh enqueue failed: pipeline_id=#{id} error=#{e.class.name}")
  end

  def ensure_stage_visits_detachable
    return if ::Crm::StageVisit.references_detachable? || !stage_visits.exists?

    errors.add(:base, 'deals have passed through this pipeline')
    throw :abort
  end

  def assign_position
    return if position.present?

    self.position = account.crm_pipelines.maximum(:position).to_i + 1 if account.present?
  end

  def clear_other_defaults
    account.crm_pipelines.where.not(id: id).where(default: true).find_each do |pipeline|
      pipeline.update!(default: false)
    end
  end

  def disable_default_when_inactive
    return if active?

    self.default = false
  end

  def reassigning_default?
    active_default? && default_state_changing?
  end

  def active_default?
    default? && active? && account.present?
  end

  def default_state_changing?
    new_record? || will_save_change_to_default? || will_save_change_to_active?
  end

  def normalize_code
    base = code.presence || name
    self.code = ::Crm::CodeNormalizer.normalize(base)
  end

  def normalize_name
    self.name = name.to_s.strip
  end
end
