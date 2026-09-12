class Crm::TaskType < ApplicationRecord
  self.table_name = 'crm_task_types'

  DEFAULT_ICON = 'i-lucide-list-todo'.freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :customer_task_assignee, class_name: '::User', optional: true
  belongs_to :customer_task_team, class_name: '::Team', optional: true
  has_many :outcomes,
           -> { ordered },
           class_name: '::Crm::TaskOutcome',
           foreign_key: :task_type_id,
           inverse_of: :task_type,
           dependent: :restrict_with_exception
  has_many :tasks,
           class_name: '::Crm::Task',
           inverse_of: :task_type,
           dependent: :restrict_with_exception

  validates :name, :code, :icon, presence: true
  validates :code, uniqueness: { scope: :account_id }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :customer_task_route_belongs_to_account

  scope :ordered, -> { order(:position, :id) }
  scope :active, -> { where(active: true) }

  before_validation :normalize_attributes
  before_validation :assign_position, on: :create
  before_save :clear_other_defaults, if: :reassigning_default?

  private

  def normalize_attributes
    self.name = name.to_s.strip
    self.code = Crm::CodeNormalizer.normalize(code.presence || name)
    self.icon = icon.to_s.strip.presence || DEFAULT_ICON
    self.default = false unless active?
  end

  def assign_position
    return if position.present?

    self.position = account&.crm_task_types&.maximum(:position).to_i + 1
  end

  def clear_other_defaults
    account.crm_task_types.where.not(id: id).where(default: true).find_each do |task_type|
      task_type.update!(default: false)
    end
  end

  def customer_task_route_belongs_to_account
    errors.add(:customer_task_assignee, 'must belong to the account') if customer_task_assignee_from_other_account?
    errors.add(:customer_task_team, 'must belong to the account') if customer_task_team_from_other_account?
    return unless customer_task_assignee && customer_task_team
    return if TeamMember.exists?(team_id: customer_task_team.id, user_id: customer_task_assignee.id)

    errors.add(:customer_task_assignee, 'must belong to the customer task team')
  end

  def customer_task_assignee_from_other_account?
    customer_task_assignee && !account.users.exists?(customer_task_assignee.id)
  end

  def customer_task_team_from_other_account?
    customer_task_team && customer_task_team.account_id != account_id
  end

  def reassigning_default?
    default? && active? && account.present? &&
      (new_record? || will_save_change_to_default? || will_save_change_to_active?)
  end
end
