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

  validates :name, presence: true
  validates :code, presence: true, uniqueness: { scope: :account_id }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :ordered, -> { order(:position, :id) }
  scope :active, -> { where(active: true) }

  before_validation :normalize_name
  before_validation :normalize_code
  before_validation :assign_position, on: :create
  before_validation :disable_default_when_inactive
  before_save :clear_other_defaults, if: :reassigning_default?

  private

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
