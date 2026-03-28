# == Schema Information
#
# Table name: crm_task_statuses
#
#  id         :bigint           not null, primary key
#  active     :boolean          default(TRUE), not null
#  category   :string           default("open"), not null
#  code       :string           not null
#  color      :string           default("#F0F0F3"), not null
#  default    :boolean          default(FALSE), not null
#  name       :string           not null
#  position   :integer          default(0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :bigint           not null
#
# Indexes
#
#  index_crm_task_statuses_on_account_default_open  (account_id) UNIQUE WHERE (("default" = true) AND ((category)::text = 'open'::text))
#  index_crm_task_statuses_on_account_id            (account_id)
#  index_crm_task_statuses_on_account_id_and_code   (account_id,code) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class Crm::TaskStatus < ApplicationRecord
  self.table_name = 'crm_task_statuses'

  CATEGORIES = %w[open in_progress done archived].freeze
  STANDARD_COLORS = [
    '#F0F0F3',
    '#E8E8EC',
    '#0EA5E9',
    '#3B82F6',
    '#6366F1',
    '#8B5CF6',
    '#A855F7',
    '#EC4899',
    '#F97316',
    '#EAB308',
    '#22C55E',
    '#14B8A6'
  ].freeze
  DEFAULT_COLOR = STANDARD_COLORS.first
  HEX_COLOR_FORMAT = /\A#[A-F0-9]{6}\z/i

  belongs_to :account, class_name: '::Account'
  has_many :tasks, class_name: '::Crm::Task', foreign_key: :status_id, inverse_of: :status, dependent: :restrict_with_exception

  enum :category, {
    open: 'open',
    in_progress: 'in_progress',
    done: 'done',
    archived: 'archived'
  }, prefix: true

  validates :name, presence: true
  validates :code, presence: true, uniqueness: { scope: :account_id }
  validates :category, inclusion: { in: CATEGORIES }
  validates :color, presence: true, format: { with: HEX_COLOR_FORMAT }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :standard_color_available_within_account

  scope :ordered, -> { order(:position, :id) }
  scope :active, -> { where(active: true) }

  before_validation :assign_default_color, on: :create
  before_validation :normalize_name
  before_validation :normalize_code
  before_validation :normalize_color
  before_validation :assign_position, on: :create
  before_validation :disable_default_unless_open
  before_save :clear_other_defaults, if: :reassigning_default?

  private

  def assign_position
    return if position.present?

    self.position = account.crm_task_statuses.maximum(:position).to_i + 1 if account.present?
  end

  def clear_other_defaults
    account.crm_task_statuses.where.not(id: id).where(default: true).find_each do |task_status|
      task_status.update!(default: false)
    end
  end

  def disable_default_unless_open
    self.default = false unless category_open? && active?
  end

  def reassigning_default?
    open_default? && default_state_changing?
  end

  def open_default?
    default? && category_open? && active? && account.present?
  end

  def default_state_changing?
    new_record? || will_save_change_to_default? || will_save_change_to_category? || will_save_change_to_active?
  end

  def normalize_code
    base = code.presence || name
    self.code = ::Crm::CodeNormalizer.normalize(base)
  end

  def normalize_color
    self.color = color.to_s.strip.upcase if color.present?
  end

  def normalize_name
    self.name = name.to_s.strip
  end

  def assign_default_color
    return if color.present?

    self.color = next_available_standard_color
  end

  def standard_color_available_within_account
    return if color.blank? || account.blank?
    return unless STANDARD_COLORS.include?(color.to_s.upcase)

    sibling_task_statuses = self.class.where(account_id: account_id)
    sibling_task_statuses = sibling_task_statuses.where.not(id: id) if id.present?

    return unless sibling_task_statuses.where('UPPER(color) = ?', color.to_s.upcase).exists?

    errors.add(:color, 'has already been taken for this account')
  end

  def next_available_standard_color
    sibling_task_statuses = self.class.where(account_id: account_id)
    sibling_task_statuses = sibling_task_statuses.where.not(id: id) if id.present?

    used_colors = sibling_task_statuses.pluck(:color).map do |value|
      value.to_s.strip.upcase
    end

    STANDARD_COLORS.find { |candidate| !used_colors.include?(candidate) } || DEFAULT_COLOR
  end
end
