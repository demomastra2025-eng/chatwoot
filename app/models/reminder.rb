# == Schema Information
#
# Table name: reminders
#
#  id                      :bigint           not null, primary key
#  action_type             :integer          default("send_message"), not null
#  attachments             :jsonb            not null
#  attempts_count          :integer          default(0), not null
#  auto_cancel_on_incoming :boolean          default(TRUE), not null
#  body                    :text
#  cancelled_at            :datetime
#  completed_at            :datetime
#  content_kind            :integer          default("free_text"), not null
#  fingerprint             :string
#  instructions            :text
#  last_error              :text
#  metadata                :jsonb            not null
#  processing_started_at   :datetime
#  relative_anchor         :string
#  relative_offset_seconds :integer          default(0), not null
#  remindable_type         :string
#  repeat_mode             :integer          default("once"), not null
#  repeat_until_at         :datetime
#  scheduled_at            :datetime
#  status                  :integer          default("draft"), not null
#  template_params         :jsonb            not null
#  text_mode               :integer          default("static"), not null
#  timezone                :string           default("UTC"), not null
#  timing_mode             :integer          default("absolute"), not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  account_id              :bigint           not null
#  conversation_id         :bigint
#  creator_id              :bigint
#  owner_id                :bigint
#  remindable_id           :bigint
#  reminder_group_id       :bigint
#  target_contact_id       :bigint
#  target_contact_inbox_id :bigint
#  target_conversation_id  :bigint
#  target_inbox_id         :bigint
#
# Indexes
#
#  idx_reminders_on_account_fingerprint        (account_id,fingerprint)
#  idx_reminders_on_account_owner_scheduled    (account_id,owner_id,scheduled_at)
#  idx_reminders_on_account_repeat_scheduled   (account_id,repeat_mode,scheduled_at)
#  idx_reminders_on_account_status_scheduled   (account_id,status,scheduled_at)
#  index_reminders_on_account_id               (account_id)
#  index_reminders_on_conversation_id          (conversation_id)
#  index_reminders_on_creator_id               (creator_id)
#  index_reminders_on_owner_id                 (owner_id)
#  index_reminders_on_remindable               (remindable_type,remindable_id)
#  index_reminders_on_reminder_group_id        (reminder_group_id)
#  index_reminders_on_target_contact_id        (target_contact_id)
#  index_reminders_on_target_contact_inbox_id  (target_contact_inbox_id)
#  index_reminders_on_target_conversation_id   (target_conversation_id)
#  index_reminders_on_target_inbox_id          (target_inbox_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (owner_id => users.id)
#  fk_rails_...  (reminder_group_id => reminder_groups.id)
#  fk_rails_...  (target_contact_id => contacts.id)
#  fk_rails_...  (target_contact_inbox_id => contact_inboxes.id)
#  fk_rails_...  (target_conversation_id => conversations.id)
#  fk_rails_...  (target_inbox_id => inboxes.id)
#
# rubocop:disable Metrics/ClassLength
class Reminder < ApplicationRecord
  include AccountStorageLimitable

  OPEN_STATUSES = %w[draft pending processing].freeze
  CONVERSATION_RELATIVE_ANCHORS = %w[
    conversation.created_at
    conversation.last_activity_at
    conversation.last_incoming_message_at
    conversation.last_outgoing_message_at
    conversation.waiting_since
  ].freeze
  CONVERSATION_DYNAMIC_RELATIVE_ANCHORS = (
    CONVERSATION_RELATIVE_ANCHORS - ['conversation.created_at']
  ).freeze
  RELATIVE_ANCHORS = %w[
    touch.created_at
    appointment.created_at
    appointment.starts_at
    appointment.ends_at
    task.created_at
    task.due_at
    deal.created_at
    deal.expected_close_on
  ].concat(CONVERSATION_RELATIVE_ANCHORS).freeze

  belongs_to :account
  belongs_to :creator, class_name: 'User', optional: true
  belongs_to :owner, class_name: 'User', optional: true
  belongs_to :conversation, optional: true
  belongs_to :target_inbox, class_name: 'Inbox', optional: true
  belongs_to :target_contact, class_name: 'Contact', optional: true
  belongs_to :target_contact_inbox, class_name: 'ContactInbox', optional: true
  belongs_to :target_conversation, class_name: 'Conversation', optional: true
  belongs_to :reminder_group, optional: true
  belongs_to :remindable, polymorphic: true, optional: true

  has_many_attached :files
  account_storage_attachments :files

  enum :status, {
    draft: 0,
    pending: 1,
    processing: 2,
    completed: 3,
    cancelled: 4,
    failed: 5
  }
  enum :action_type, {
    send_message: 0,
    ai_agent_wakeup: 1
  }
  enum :content_kind, {
    free_text: 0,
    channel_template: 1
  }
  enum :text_mode, {
    static: 0,
    dynamic: 1,
    agent: 2
  }
  enum :timing_mode, {
    absolute: 0,
    relative: 1
  }
  enum :repeat_mode, {
    once: 0,
    daily: 1,
    weekly: 2,
    monthly: 3,
    weekdays: 4
  }

  validates :timezone, inclusion: { in: TZInfo::Timezone.all_identifiers }
  validates :relative_anchor, inclusion: { in: RELATIVE_ANCHORS }, allow_blank: true
  validate :validate_account_matches
  validate :validate_json_field_shapes
  validate :validate_content_requirements
  validate :validate_delivery_policy
  validate :validate_repeat_requirements
  validate :validate_open_duplicate_absence

  before_validation :normalize_json_fields
  before_validation :normalize_text_mode
  before_validation :sync_account_from_associations
  before_validation :hydrate_target_defaults
  before_validation :assign_owner_default, on: :create
  before_validation :normalize_repeat_fields
  before_validation :materialize_schedule
  before_validation :assign_default_status
  before_validation :refresh_fingerprint
  after_create :retain_attachment_blobs

  scope :ordered, -> { order(scheduled_at: :asc, created_at: :asc, id: :asc) }
  scope :open_statuses, -> { where(status: OPEN_STATUSES) }
  scope :due, -> { where('scheduled_at <= ?', Time.current) }

  def ready_for_pending?
    scheduled_at.present? && route_resolved? && content_ready?
  end

  def approve!
    raise_invalid_record! unless ready_for_pending?

    update!(
      status: :pending,
      cancelled_at: nil,
      last_error: nil
    )
  end

  def cancel!(reason = nil)
    update!(
      status: :cancelled,
      cancelled_at: Time.current,
      last_error: reason.presence || last_error
    )
  end

  def mark_processing!
    update!(
      status: :processing,
      processing_started_at: Time.current,
      last_error: nil
    )
  end

  def complete!
    update!(
      status: :completed,
      completed_at: Time.current
    )
  end

  def fail!(message)
    update!(
      status: :failed,
      last_error: message,
      attempts_count: attempts_count.to_i + 1
    )
  end

  def destroyable?
    draft? || pending? || failed? || cancelled?
  end

  def renderable_body(conversation: nil, sender: nil)
    Outbound::RenderedTextService.new(
      content: body,
      conversation: conversation || target_conversation || self.conversation,
      contact: target_contact,
      inbox: target_inbox,
      account: account,
      sender: sender || message_sender
    ).render
  end

  def recurring?
    !once?
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  def message_sender
    owner || creator || conversation&.assignee || account&.administrators&.order(:id)&.first
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def open_duplicate_scope
    scope = self.class.where(account_id: account_id, fingerprint: fingerprint, status: self.class.statuses.slice(*OPEN_STATUSES).values)
    persisted? ? scope.where.not(id: id) : scope
  end

  private

  # rubocop:disable Metrics/CyclomaticComplexity
  def assign_default_status
    return if cancelled? || completed? || failed?

    self.status ||= ready_for_pending? ? :pending : :draft
    self.status = :draft if pending? && !ready_for_pending?
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def assign_owner_default
    return if owner.present?

    self.owner = case remindable
                 when Conversation, Crm::Task
                   remindable.assignee
                 when Crm::Deal
                   remindable.owner
                 when Scheduling::Appointment
                   remindable.created_by
                 end
  end

  def content_ready?
    return target_conversation_id.present? || conversation_id.present? if ai_agent_wakeup?
    return false unless send_message?
    return instructions.present? if agent?
    return template_params.present? if channel_template?

    body.present? || attachments.present? || files.attached?
  end

  def materialize_schedule
    return unless relative?

    anchor_time = relative_anchor_time
    if anchor_time.blank?
      self.scheduled_at = nil
      self.status = :draft if status.blank? || pending?
      return
    end

    self.scheduled_at = anchor_time + relative_offset_seconds.to_i.seconds
  end

  def normalize_json_fields
    self.attachments = Array(attachments).compact
    self.template_params = (template_params || {}).to_h
    self.metadata = (metadata || {}).to_h
  end

  def retain_attachment_blobs
    return if attachments.blank?

    files.attach(attachments)
  end

  def normalize_text_mode
    self.text_mode = Reminders::TextModeResolver.call(
      action_type: action_type,
      body: body,
      instructions: instructions,
      text_mode: text_mode
    )
  end

  def normalize_repeat_fields
    self.repeat_mode ||= :once
    self.repeat_until_at = nil if once?
  end

  def refresh_fingerprint
    digest_source = [
      remindable_type,
      remindable_id,
      action_type,
      target_inbox_id,
      target_contact_id,
      target_contact_inbox_id,
      target_conversation_id,
      scheduled_at&.utc&.iso8601,
      content_kind,
      text_mode,
      body.to_s.strip,
      instructions.to_s.strip,
      template_params.to_json,
      attachments.to_json
    ].join('|')

    self.fingerprint = Digest::SHA256.hexdigest(digest_source)
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  def relative_anchor_time
    case relative_anchor
    when 'touch.created_at'
      # New delayed messages do not have created_at yet during before_validation.
      # Use the current server time so "after creation" touches materialize immediately.
      created_at || Time.current
    when 'appointment.created_at'
      remindable.try(:created_at)
    when 'appointment.starts_at'
      remindable.try(:starts_at)
    when 'appointment.ends_at'
      remindable.try(:ends_at)
    when 'task.created_at'
      remindable.try(:created_at)
    when 'task.due_at'
      remindable.try(:due_at)
    when 'deal.created_at'
      remindable.try(:created_at)
    when 'deal.expected_close_on'
      remindable.try(:expected_close_on)&.in_time_zone
    when 'conversation.created_at'
      anchor_conversation&.created_at
    when 'conversation.last_activity_at'
      anchor_conversation&.last_activity_at
    when 'conversation.last_incoming_message_at'
      last_conversation_message_at(:incoming)
    when 'conversation.last_outgoing_message_at'
      last_conversation_message_at(:outgoing)
    when 'conversation.waiting_since'
      anchor_conversation&.waiting_since
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def anchor_conversation
    target_conversation || conversation || (remindable if remindable.is_a?(Conversation))
  end

  def last_conversation_message_at(message_type)
    return if anchor_conversation.blank?

    anchor_conversation.messages
                       .where(account_id: account_id, message_type: Message.message_types.fetch(message_type.to_s), private: false)
                       .reorder(created_at: :desc)
                       .limit(1)
                       .pick(:created_at)
  end

  def route_resolved?
    return target_conversation_id.present? || conversation_id.present? if ai_agent_wakeup?

    target_inbox_id.present? && (
      target_contact_inbox_id.present? ||
      target_contact_id.present? ||
      target_conversation_id.present? ||
      conversation_id.present?
    )
  end

  def sync_account_from_associations
    self.account ||= remindable.try(:account) || conversation&.account || target_inbox&.account
  end

  def hydrate_target_defaults
    return if remindable.blank?

    case remindable
    when Conversation
      hydrate_from_conversation(remindable)
    when Crm::Deal
      hydrate_from_deal(remindable)
    when Crm::Task
      hydrate_from_task(remindable)
    when Scheduling::Appointment
      hydrate_from_appointment(remindable)
    end
  end

  def hydrate_from_appointment(appointment)
    hydrate_from_conversation(appointment.conversation) if appointment.conversation.present?
    self.target_contact ||= appointment.contact
  end

  def hydrate_from_conversation(record)
    return if record.blank?

    self.conversation ||= record
    self.target_conversation ||= record
    self.target_inbox ||= record.inbox
    self.target_contact ||= record.contact
    self.target_contact_inbox ||= record.contact_inbox
  end

  def hydrate_from_deal(deal)
    hydrate_from_conversation(deal.originating_conversation) if deal.originating_conversation.present?
    self.target_contact ||= deal.contacts.first
  end

  def hydrate_from_task(task)
    hydrate_from_conversation(task.originating_conversation) if task.originating_conversation.present?
    self.target_contact ||= task.deal&.contacts&.first
  end

  def validate_account_matches
    validate_account_match(:creator, creator)
    validate_account_match(:owner, owner)
    validate_account_match(:conversation, conversation)
    validate_account_match(:target_inbox, target_inbox)
    validate_account_match(:target_contact, target_contact)
    validate_account_match(:target_contact_inbox, target_contact_inbox)
    validate_account_match(:target_conversation, target_conversation)
    validate_account_match(:reminder_group, reminder_group)
    validate_account_match(:remindable, remindable)
  end

  def validate_json_field_shapes
    errors.add(:attachments, 'must be an array') unless attachments.is_a?(Array)
    errors.add(:template_params, 'must be an object') unless template_params.is_a?(Hash)
    errors.add(:metadata, 'must be an object') unless metadata.is_a?(Hash)
  end

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def validate_account_match(attribute_name, record)
    return if record.blank? || account.blank?
    return if record.is_a?(User) && account.users.exists?(id: record.id)
    return if record.is_a?(ContactInbox) && record.inbox&.account_id == account_id
    return if record.respond_to?(:account_id) && record.account_id == account_id
    return if record.is_a?(ReminderGroup) && record.account_id == account_id

    errors.add(attribute_name, 'must belong to the current account')
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def validate_content_requirements
    return unless send_message?

    if agent? && instructions.blank?
      errors.add(:instructions, 'must be present for agent touches')
    elsif channel_template? && template_params.blank?
      errors.add(:template_params, 'must be present for channel template touches')
    elsif free_text? && !agent? && body.blank? && attachments.blank? && !files.attached?
      errors.add(:body, 'must be present for message touches')
    end
  end

  def validate_delivery_policy
    return unless delivery_policy_ready_for_validation?

    ::Outbound::DeliveryPolicy.ensure!(
      conversation: delivery_policy_conversation,
      inbox: target_inbox,
      content_kind: delivery_policy_content_kind,
      template_params: template_params,
      attachments: attachments,
      scheduled_at: scheduled_at
    )
  rescue ArgumentError => e
    errors.add(:base, e.message)
  end

  def delivery_policy_ready_for_validation?
    return false unless send_message?
    return false if target_inbox.blank? || scheduled_at.blank?
    return true if channel_template? && template_params.present?
    return true if agent? && instructions.present?

    free_text? && (body.present? || attachments.present? || files.attached?)
  end

  def delivery_policy_content_kind
    return 'channel_template' if channel_template? || template_params.present?

    'free_text'
  end

  def delivery_policy_conversation
    target_conversation || conversation || (remindable if remindable.is_a?(Conversation))
  end

  def validate_repeat_requirements
    return unless recurring?

    errors.add(:repeat_mode, 'is only supported for absolute touches') unless absolute?

    return unless repeat_until_at.present? && scheduled_at.present? && repeat_until_at <= scheduled_at

    errors.add(:repeat_until_at, 'must be after the first scheduled time')
  end

  def validate_open_duplicate_absence
    return if fingerprint.blank? || account_id.blank?
    return unless open_duplicate_scope.exists?

    errors.add(:base, 'An open touch with the same content already exists')
  end

  # rubocop:disable Style/RaiseArgs
  def raise_invalid_record!
    raise ActiveRecord::RecordInvalid.new(self)
  end
  # rubocop:enable Style/RaiseArgs
end
# rubocop:enable Metrics/ClassLength
