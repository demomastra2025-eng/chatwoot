class Crm::TaskOutcome < ApplicationRecord
  self.table_name = 'crm_task_outcomes'

  belongs_to :account, class_name: '::Account'
  belongs_to :task_type, class_name: '::Crm::TaskType', inverse_of: :outcomes
  has_many :tasks,
           class_name: '::Crm::Task',
           inverse_of: :task_outcome,
           dependent: :restrict_with_exception

  validates :name, :code, presence: true
  validates :code, uniqueness: { scope: :task_type_id }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :task_type_belongs_to_account

  scope :ordered, -> { order(:position, :id) }
  scope :active, -> { where(active: true) }

  before_validation :normalize_attributes
  before_validation :assign_position, on: :create
  before_save :clear_other_defaults, if: :reassigning_default?

  private

  def normalize_attributes
    self.name = name.to_s.strip
    self.code = Crm::CodeNormalizer.normalize(code.presence || name)
    self.default = false unless active?
  end

  def assign_position
    return if position.present?

    self.position = task_type&.outcomes&.maximum(:position).to_i + 1
  end

  def task_type_belongs_to_account
    return if task_type.blank? || task_type.account_id == account_id

    errors.add(:task_type, 'must belong to the current account')
  end

  def clear_other_defaults
    task_type.outcomes.where.not(id: id).where(default: true).find_each do |outcome|
      outcome.update!(default: false)
    end
  end

  def reassigning_default?
    default? && active? && task_type.present? &&
      (new_record? || will_save_change_to_default? || will_save_change_to_active?)
  end
end
