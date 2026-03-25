# == Schema Information
#
# Table name: crm_task_statuses
#
#  id         :bigint           not null, primary key
#  active     :boolean          default(TRUE), not null
#  category   :string           default("open"), not null
#  code       :string           not null
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

  CATEGORIES = %w[open done archived].freeze

  belongs_to :account, class_name: '::Account'

  enum :category, {
    open: 'open',
    done: 'done',
    archived: 'archived'
  }, prefix: true

  validates :name, presence: true
  validates :code, presence: true, uniqueness: { scope: :account_id }
  validates :category, inclusion: { in: CATEGORIES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :ordered, -> { order(:position, :id) }
  scope :active, -> { where(active: true) }

  before_validation :normalize_name
  before_validation :normalize_code
  before_validation :assign_position, on: :create
  before_validation :disable_default_unless_open
  after_commit :clear_other_defaults, on: %i[create update], if: :default?

  private

  def assign_position
    return if position.present?

    self.position = account.crm_task_statuses.maximum(:position).to_i + 1 if account.present?
  end

  def clear_other_defaults
    account.crm_task_statuses.where.not(id: id).find_each do |task_status|
      task_status.update!(default: false)
    end
  end

  def disable_default_unless_open
    self.default = false unless category_open? && active?
  end

  def normalize_code
    base = code.presence || name
    self.code = base.to_s.parameterize(separator: '_')
  end

  def normalize_name
    self.name = name.to_s.strip
  end
end
