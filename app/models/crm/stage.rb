# == Schema Information
#
# Table name: crm_stages
#
#  id                         :bigint           not null, primary key
#  active                     :boolean          default(TRUE), not null
#  closing_reason_options     :jsonb            not null
#  closing_reason_required    :boolean          default(FALSE), not null
#  code                       :string           not null
#  color                      :string           default("#E11D48"), not null
#  default                    :boolean          default(FALSE), not null
#  name                       :string           not null
#  outcome                    :string           default("open"), not null
#  position                   :integer          default(0), not null
#  transition_reason_options  :jsonb            not null
#  transition_reason_required :boolean          default(FALSE), not null
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  account_id                 :bigint           not null
#  pipeline_id                :bigint           not null
#
# Indexes
#
#  index_crm_stages_on_account_id                 (account_id)
#  index_crm_stages_on_account_pipeline_position  (account_id,pipeline_id,position)
#  index_crm_stages_on_pipeline_default_active    (pipeline_id) UNIQUE WHERE (("default" = true) AND (active = true))
#  index_crm_stages_on_pipeline_id                (pipeline_id)
#  index_crm_stages_on_pipeline_id_and_code       (pipeline_id,code) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (pipeline_id => crm_pipelines.id)
#
class Crm::Stage < ApplicationRecord
  include AccountCacheRevalidator

  self.table_name = 'crm_stages'

  OUTCOMES = %w[open won lost].freeze
  TERMINAL_OUTCOMES = %w[won lost].freeze
  TECHNICAL_STAGE_CODES = %w[new].freeze
  STANDARD_COLORS = [
    '#E11D48',
    '#DC2626',
    '#EA580C',
    '#F97316',
    '#D97706',
    '#CA8A04',
    '#84CC16',
    '#65A30D',
    '#16A34A',
    '#059669',
    '#0D9488',
    '#0891B2',
    '#0284C7',
    '#2563EB',
    '#4F46E5',
    '#7C3AED',
    '#9333EA',
    '#C026D3',
    '#DB2777',
    '#BE123C'
  ].freeze
  WON_COLOR = '#16A34A'.freeze
  LOST_COLOR = '#DC2626'.freeze
  DEFAULT_COLOR = STANDARD_COLORS.first
  HEX_COLOR_FORMAT = /\A#[A-F0-9]{6}\z/i
  SYSTEM_STAGE_SORT_SQL = Arel.sql(<<~SQL.squish).freeze
    CASE
      WHEN crm_stages.code = 'new' THEN 0
      WHEN crm_stages.outcome = 'open' THEN 1
      WHEN crm_stages.outcome = 'won' THEN 2
      WHEN crm_stages.outcome = 'lost' THEN 3
      ELSE 4
    END
  SQL

  belongs_to :account, class_name: '::Account'
  belongs_to :pipeline, class_name: '::Crm::Pipeline', inverse_of: :stages
  has_many :deals, class_name: '::Crm::Deal', dependent: :restrict_with_error, inverse_of: :stage

  enum :outcome, {
    open: 'open',
    won: 'won',
    lost: 'lost'
  }, prefix: true

  validates :name, presence: true
  validates :code, presence: true, uniqueness: { scope: :pipeline_id }
  validates :color, presence: true, format: { with: HEX_COLOR_FORMAT }
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :pipeline_belongs_to_account
  validate :default_stage_must_be_active_open
  validate :closing_reason_required_requires_options
  validate :transition_reason_required_requires_options

  scope :ordered, -> { order(SYSTEM_STAGE_SORT_SQL, :position, :id) }
  scope :active, -> { where(active: true) }

  before_validation :sync_account_id
  before_validation :assign_default_color, on: :create
  before_validation :assign_default_for_first_open_stage, on: :create
  before_validation :normalize_name
  before_validation :normalize_code
  before_validation :normalize_color
  before_validation :normalize_closing_reason_config
  before_validation :normalize_transition_reason_config
  before_validation :assign_position, on: :create
  before_save :clear_other_default_stages, if: :default?
  before_create :shift_sibling_positions_for_insert

  class << self
    def normalize_closing_reason_values(values)
      Array(values).filter_map do |value|
        reason = if value.respond_to?(:key?)
                   value[:label] || value['label'] || value[:value] || value['value']
                 else
                   value
                 end

        reason.to_s.strip.presence
      end.uniq
    end
  end

  def terminal_outcome?
    outcome.in?(TERMINAL_OUTCOMES)
  end

  def technical_stage?
    code.in?(TECHNICAL_STAGE_CODES)
  end

  def system_stage?
    technical_stage? || terminal_outcome?
  end

  def position_locked?
    system_stage?
  end

  def canonical_closing_reasons(values)
    normalized_values = self.class.normalize_closing_reason_values(values)
    return [] if normalized_values.blank?

    options_by_key = closing_reason_options.index_by { |reason| reason.to_s.downcase }
    normalized_values.filter_map do |reason|
      options_by_key[reason.to_s.downcase]
    end.uniq
  end

  def invalid_closing_reasons(values)
    normalized_values = self.class.normalize_closing_reason_values(values)
    canonical_values = canonical_closing_reasons(normalized_values)

    normalized_values.reject do |reason|
      canonical_values.any? { |canonical_reason| canonical_reason.casecmp?(reason) }
    end
  end

  def canonical_transition_reason(value)
    reason = self.class.normalize_closing_reason_values([value]).first
    return if reason.blank?

    options_by_key = transition_reason_options.index_by { |option| option.to_s.downcase }
    options_by_key[reason.to_s.downcase]
  end

  def invalid_transition_reason(value)
    reason = self.class.normalize_closing_reason_values([value]).first
    return [] if reason.blank?
    return [] if canonical_transition_reason(reason).present?

    [reason]
  end

  private

  def assign_position
    return if position.present?
    return if pipeline.blank?

    terminal_position = pipeline.stages.where(outcome: TERMINAL_OUTCOMES).minimum(:position)

    if outcome_open? && terminal_position.present?
      self.position = terminal_position
      @shift_sibling_positions_for_insert = true
    else
      self.position = pipeline.stages.maximum(:position).to_i + 1
    end
  end

  def shift_sibling_positions_for_insert
    return unless @shift_sibling_positions_for_insert
    return if pipeline_id.blank? || position.blank?

    self.class
        .where(pipeline_id: pipeline_id)
        .where('position >= ?', position)
        .order(position: :desc, id: :desc)
        .each { |stage| stage.update!(position: stage.position + 1) }
  end

  def normalize_code
    generated_code = code.blank?
    normalized_code = ::Crm::CodeNormalizer.normalize(code.presence || name)
    duplicate_code = generated_code && pipeline&.stages&.where(code: normalized_code)&.exists?
    normalized_code = "#{normalized_code}_#{SecureRandom.hex(6)}" if duplicate_code

    self.code = normalized_code
  end

  def normalize_name
    self.name = name.to_s.strip
  end

  def normalize_color
    self.color = color.to_s.strip.upcase if color.present?
  end

  def normalize_closing_reason_config
    self.closing_reason_options = self.class.normalize_closing_reason_values(closing_reason_options)

    if terminal_outcome?
      self.closing_reason_required = false
      return
    end

    self.closing_reason_options = []
    self.closing_reason_required = false
  end

  def normalize_transition_reason_config
    self.transition_reason_options = self.class.normalize_closing_reason_values(transition_reason_options)

    return if outcome_open?

    self.transition_reason_options = []
    self.transition_reason_required = false
  end

  def closing_reason_required_requires_options
    return unless terminal_outcome?
    return unless closing_reason_required?
    return if closing_reason_options.present?

    errors.add(:closing_reason_options, 'must include at least one reason when required')
  end

  def transition_reason_required_requires_options
    return unless outcome_open?
    return unless transition_reason_required?
    return if transition_reason_options.present?

    errors.add(:transition_reason_options, 'must include at least one reason when required')
  end

  def assign_default_color
    return if color.present?

    self.color = next_available_standard_color
  end

  def pipeline_belongs_to_account
    return if pipeline.blank? || pipeline.account_id == account_id

    errors.add(:pipeline_id, 'must belong to the current account')
  end

  def default_stage_must_be_active_open
    return unless default?
    return if active? && outcome_open?

    errors.add(:default, 'must be an active open stage')
  end

  def sync_account_id
    self.account_id = pipeline.account_id if pipeline.present?
  end

  def assign_default_for_first_open_stage
    return if default?
    return unless active? && outcome_open?
    return if pipeline.blank?
    return if pipeline.stages.active.exists?(default: true)

    self.default = true
  end

  def next_available_standard_color
    sibling_stages = self.class.where(pipeline_id: pipeline_id)
    sibling_stages = sibling_stages.where.not(id: id) if id.present?

    used_colors = sibling_stages.pluck(:color).map do |value|
      value.to_s.strip.upcase
    end

    STANDARD_COLORS.find { |candidate| used_colors.exclude?(candidate) } || DEFAULT_COLOR
  end

  def clear_other_default_stages
    sibling_defaults = self.class.where(
      pipeline_id: pipeline_id,
      default: true
    ).where.not(id: id)
    sibling_defaults.find_each { |stage| stage.update!(default: false) }
  end
end
