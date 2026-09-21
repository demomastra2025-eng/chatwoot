class Crm::StageVisit < ApplicationRecord
  self.table_name = 'crm_stage_visits'

  # Nil intentionally includes legacy and mixed-version overlap rows. Versioned
  # attribution is exact only after every old writer has been drained.
  TERMINAL_ATTRIBUTION_VERSION = 1

  belongs_to :account, class_name: '::Account'
  belongs_to :deal, class_name: '::Crm::Deal', inverse_of: :stage_visits
  belongs_to :pipeline, class_name: '::Crm::Pipeline', inverse_of: :stage_visits
  belongs_to :stage, class_name: '::Crm::Stage', inverse_of: :stage_visits

  validates :entered_at, :reliable_since, :pipeline_name, :stage_name, :stage_outcome, :correlation_id, presence: true
  validates :stage_outcome, inclusion: { in: Crm::Stage::OUTCOMES }
  validates :terminal_attribution_version, inclusion: { in: [TERMINAL_ATTRIBUTION_VERSION] }, allow_nil: true
  validate :references_belong_to_account
  validate :terminal_attribution_references_belong_to_account
  validate :terminal_attribution_is_consistent
  validate :valid_interval

  before_update :allow_only_first_close
  before_destroy :prevent_destroy

  scope :active, -> { where(exited_at: nil) }
  scope :ordered, -> { order(entered_at: :asc, id: :asc) }

  def active?
    exited_at.nil?
  end

  private

  def allow_only_first_close
    allowed_changes = %w[exited_at updated_at]
    return if exited_at_was.nil? && exited_at.present? && (changes.keys - allowed_changes).empty?

    errors.add(:base, 'stage visits are append-only')
    throw :abort
  end

  def prevent_destroy
    errors.add(:base, 'stage visits are append-only')
    throw :abort
  end

  def references_belong_to_account
    errors.add(:deal, 'must belong to the account') if deal.present? && deal.account_id != account_id
    errors.add(:pipeline, 'must belong to the account') if pipeline.present? && pipeline.account_id != account_id
    errors.add(:stage, 'must belong to the account') if stage.present? && stage.account_id != account_id
  end

  def terminal_attribution_references_belong_to_account
    return unless new_record? || terminal_attribution_changed?

    if owner_id_at_terminal.present? && !account.users.exists?(id: owner_id_at_terminal)
      errors.add(:owner_id_at_terminal, 'must belong to the account')
    end
    errors.add(:team_id_at_terminal, 'must belong to the account') if team_id_at_terminal.present? && !account.teams.exists?(id: team_id_at_terminal)
  end

  def terminal_attribution_is_consistent
    captured = terminal_attribution_version.present?
    has_snapshot_ids = owner_id_at_terminal.present? || team_id_at_terminal.present?

    errors.add(:terminal_attribution_version, 'is required with terminal attribution') if has_snapshot_ids && !captured
    errors.add(:terminal_attribution_version, 'is only valid for terminal visits') if captured && stage_outcome == 'open'
  end

  def terminal_attribution_changed?
    will_save_change_to_owner_id_at_terminal? ||
      will_save_change_to_team_id_at_terminal? ||
      will_save_change_to_terminal_attribution_version?
  end

  def valid_interval
    return if exited_at.blank? || entered_at.blank? || exited_at >= entered_at

    errors.add(:exited_at, 'must not be before entered_at')
  end
end
