# == Schema Information
#
# Table name: reminder_groups
#
#  id           :bigint           not null, primary key
#  active       :boolean          default(TRUE), not null
#  archived_at  :datetime
#  description  :text
#  entity_kinds :jsonb            not null
#  name         :string           not null
#  touches      :jsonb            not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint           not null
#  assistant_id :bigint
#  creator_id   :bigint
#
# Indexes
#
#  idx_reminder_groups_on_account_active_created  (account_id,active,created_at)
#  index_reminder_groups_on_account_id            (account_id)
#  index_reminder_groups_on_assistant_id          (assistant_id)
#  index_reminder_groups_on_creator_id            (creator_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (assistant_id => captain_assistants.id)
#  fk_rails_...  (creator_id => users.id)
#
class ReminderGroup < ApplicationRecord
  SUPPORTED_ENTITY_KINDS = %w[conversation deal task appointment].freeze

  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant', optional: true
  belongs_to :creator, class_name: 'User', optional: true

  has_many :reminders, dependent: :nullify

  validates :name, presence: true
  validate :validate_entity_kinds
  validate :validate_assistant_account
  validate :validate_touches

  scope :ordered, -> { order(:name, :id) }
  scope :kept, -> { where(archived_at: nil) }
  scope :for_assistant_workspace, ->(assistant_id) { where(assistant_id: [assistant_id, nil]) }

  before_validation :normalize_json_fields

  def archive!
    update!(active: false, archived_at: Time.current)
  end

  def entity_kind_supported?(entity_kind)
    entity_kinds.include?(entity_kind.to_s)
  end

  private

  def normalize_json_fields
    self.entity_kinds = Array(entity_kinds).map(&:to_s).uniq
    self.touches = Array(touches).map do |item|
      Reminders::DefinitionNormalizer.call(item)
    end
  end

  def validate_entity_kinds
    unsupported_kinds = entity_kinds - SUPPORTED_ENTITY_KINDS
    return if unsupported_kinds.blank?

    errors.add(:entity_kinds, "contains unsupported kinds: #{unsupported_kinds.join(', ')}")
  end

  def validate_assistant_account
    return if assistant.blank? || account.blank?
    return if assistant.account_id == account_id

    errors.add(:assistant, 'must belong to the same account')
  end

  def validate_touches
    return if touches.all?(Hash)

    errors.add(:touches, 'must be an array of touch definitions')
  end
end
