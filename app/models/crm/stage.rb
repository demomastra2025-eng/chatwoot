# == Schema Information
#
# Table name: crm_stages
#
#  id          :bigint           not null, primary key
#  active      :boolean          default(TRUE), not null
#  code        :string           not null
#  name        :string           not null
#  outcome     :string           default("open"), not null
#  position    :integer          default(0), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  account_id  :bigint           not null
#  pipeline_id :bigint           not null
#
# Indexes
#
#  index_crm_stages_on_account_id                 (account_id)
#  index_crm_stages_on_account_pipeline_position  (account_id,pipeline_id,position)
#  index_crm_stages_on_pipeline_id                (pipeline_id)
#  index_crm_stages_on_pipeline_id_and_code       (pipeline_id,code) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (pipeline_id => crm_pipelines.id)
#
class Crm::Stage < ApplicationRecord
  self.table_name = 'crm_stages'

  OUTCOMES = %w[open won lost].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :pipeline, class_name: '::Crm::Pipeline', inverse_of: :stages

  enum :outcome, {
    open: 'open',
    won: 'won',
    lost: 'lost'
  }, prefix: true

  validates :name, presence: true
  validates :code, presence: true, uniqueness: { scope: :pipeline_id }
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :pipeline_belongs_to_account

  scope :ordered, -> { order(:position, :id) }
  scope :active, -> { where(active: true) }

  before_validation :sync_account_id
  before_validation :normalize_name
  before_validation :normalize_code
  before_validation :assign_position, on: :create

  private

  def assign_position
    return if position.present?
    return if pipeline.blank?

    self.position = pipeline.stages.maximum(:position).to_i + 1
  end

  def normalize_code
    base = code.presence || name
    self.code = base.to_s.parameterize(separator: '_')
  end

  def normalize_name
    self.name = name.to_s.strip
  end

  def pipeline_belongs_to_account
    return if pipeline.blank? || pipeline.account_id == account_id

    errors.add(:pipeline_id, 'must belong to the current account')
  end

  def sync_account_id
    self.account_id = pipeline.account_id if pipeline.present?
  end
end
