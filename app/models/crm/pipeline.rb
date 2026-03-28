# == Schema Information
#
# Table name: crm_pipelines
#
#  id         :bigint           not null, primary key
#  active     :boolean          default(TRUE), not null
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
  has_many :deals, class_name: '::Crm::Deal', inverse_of: :pipeline

  validates :name, presence: true
  validates :code, presence: true, uniqueness: { scope: :account_id }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :ordered, -> { order(:position, :id) }
  scope :active, -> { where(active: true) }

  before_validation :normalize_name
  before_validation :normalize_code
  before_validation :assign_position, on: :create
  before_validation :disable_default_when_inactive
  after_commit :clear_other_defaults, on: %i[create update], if: :default?

  private

  def assign_position
    return if position.present?

    self.position = account.crm_pipelines.maximum(:position).to_i + 1 if account.present?
  end

  def clear_other_defaults
    account.crm_pipelines.where.not(id: id).find_each do |pipeline|
      pipeline.update!(default: false)
    end
  end

  def disable_default_when_inactive
    self.default = false unless active?
  end

  def normalize_code
    base = code.presence || name
    self.code = ::Crm::CodeNormalizer.normalize(base)
  end

  def normalize_name
    self.name = name.to_s.strip
  end
end
