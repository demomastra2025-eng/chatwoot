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
  has_many :touch_plan_enrollments, dependent: :nullify

  validates :name, presence: true
  validate :validate_entity_kinds
  validate :validate_assistant_account
  validate :validate_touches
  validate :validate_post_delivery_actions

  scope :ordered, -> { order(:name, :id) }
  scope :kept, -> { where(archived_at: nil) }
  scope :for_assistant_workspace, ->(assistant_id) { where(assistant_id: [assistant_id, nil]) }

  before_validation :normalize_json_fields
  before_destroy :cancel_live_touch_enrollments, prepend: true
  after_update_commit :reconcile_live_enrollments, if: :saved_change_to_touches?

  def archive!
    update!(active: false, archived_at: Time.current)
  end

  def entity_kind_supported?(entity_kind)
    entity_kinds.include?(entity_kind.to_s)
  end

  private

  def normalize_json_fields
    self.entity_kinds = Array(entity_kinds).map(&:to_s).uniq
    self.touches = normalize_touch_ids
  end

  def normalize_touch_ids
    existing_touches = touches_in_database
    seen_step_ids = Set.new
    Array(touches).each_with_index.map do |item, index|
      definition = Reminders::DefinitionNormalizer.call(item)
      if definition.is_a?(Hash)
        previous_step_id = existing_touches[index].to_h.deep_stringify_keys['step_id']
        step_id = definition['step_id'].presence || previous_step_id.to_s
        step_id = SecureRandom.uuid if step_id.blank? || seen_step_ids.include?(step_id)
        definition['step_id'] = step_id
        seen_step_ids << step_id
      end
      definition
    end
  end

  def touches_in_database
    value = attribute_in_database('touches')
    value = JSON.parse(value) if value.is_a?(String)
    Array(value)
  rescue JSON::ParserError
    []
  end

  def reconcile_live_enrollments
    Reminders::ReconcileSourceEnrollmentsJob.perform_later('ReminderGroup', id)
  end

  def cancel_live_touch_enrollments
    touch_plan_enrollments.find_each do |enrollment|
      Reminders::CancelEnrollmentService.new(
        enrollment: enrollment,
        reason: 'live touch plan was deleted'
      ).perform
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

  def validate_post_delivery_actions
    post_delivery_touches = touches.select do |touch|
      touch.is_a?(Hash) && touch.with_indifferent_access[:post_delivery_action].present?
    end
    return if post_delivery_touches.blank?

    valid = entity_kinds == ['conversation'] && post_delivery_touches.all? do |touch|
      supported_post_delivery_action?(touch)
    end
    return if valid

    errors.add(:touches, 'contains an unsupported post-delivery action')
  end

  def supported_post_delivery_action?(touch)
    definition = touch.with_indifferent_access
    Reminder::POST_DELIVERY_ACTIONS.include?(definition[:post_delivery_action]) &&
      (definition[:action_type].presence || 'send_message').to_s == 'send_message' &&
      (definition[:repeat_mode].presence || 'once').to_s == 'once'
  end
end
