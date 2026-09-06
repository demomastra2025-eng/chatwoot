# == Schema Information
#
# Table name: reminders
#
#  id                          :bigint           not null, primary key
#  action_type                 :integer          default("send_message"), not null
#  attachments                 :jsonb            not null
#  attempts_count              :integer          default(0), not null
#  auto_cancel_on_incoming     :boolean          default(FALSE), not null
#  body                        :text
#  cancelled_at                :datetime
#  completed_at                :datetime
#  content_kind                :integer          default("free_text"), not null
#  fingerprint                 :string
#  instructions                :text
#  last_error                  :text
#  last_materialized_anchor_at :datetime
#  manual_schedule_override    :boolean          default(FALSE), not null
#  metadata                    :jsonb            not null
#  post_delivery_action        :string
#  processing_started_at       :datetime
#  relative_anchor             :string
#  relative_offset_seconds     :integer          default(0), not null
#  relative_time_mode          :string           default("inherit_anchor_time"), not null
#  relative_time_of_day        :string
#  remindable_type             :string
#  repeat_mode                 :integer          default("once"), not null
#  repeat_until_at             :datetime
#  response_action             :string
#  response_button_index       :integer
#  schedule_revision           :integer          default(0), not null
#  scheduled_at                :datetime
#  status                      :integer          default("draft"), not null
#  template_params             :jsonb            not null
#  text_mode                   :integer          default("static"), not null
#  timezone                    :string           default("UTC"), not null
#  timing_mode                 :integer          default("absolute"), not null
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  account_id                  :bigint           not null
#  conversation_id             :bigint
#  creator_id                  :bigint
#  owner_id                    :bigint
#  remindable_id               :bigint
#  reminder_group_id           :bigint
#  target_contact_id           :bigint
#  target_contact_inbox_id     :bigint
#  target_conversation_id      :bigint
#  target_inbox_id             :bigint
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
  PROCESSING_CLAIM_KEY = 'processing_claim_token'.freeze
  DELIVERY_MATERIALIZED_MESSAGE_ID_KEY = 'delivery_materialized_message_id'.freeze
  DELIVERY_DISPATCHED_MESSAGE_ID_KEY = 'delivery_dispatched_message_id'.freeze
  POST_DELIVERY_ACTION_MESSAGE_ID_KEY = 'post_delivery_action_message_id'.freeze
  POST_DELIVERY_ACTION_EXECUTED_AT_KEY = 'post_delivery_action_executed_at'.freeze
  POST_DELIVERY_ACTION_RESOLVE_CONVERSATION = 'resolve_conversation'.freeze
  POST_DELIVERY_ACTIONS = [POST_DELIVERY_ACTION_RESOLVE_CONVERSATION].freeze
  RESPONSE_ACTION_CONFIRM_APPOINTMENT = 'confirm_appointment'.freeze
  RESPONSE_ACTIONS = [RESPONSE_ACTION_CONFIRM_APPOINTMENT].freeze
  POST_DELIVERY_AUDIT_SOURCE_KEY = 'post_delivery_audit_source'.freeze
  POST_DELIVERY_AUTOMATION_RULE_ID_KEY = 'post_delivery_automation_rule_id'.freeze
  AUTOMATION_TRIGGER_MESSAGE_ID_KEY = 'automation_trigger_message_id'.freeze
  AUTOMATION_ACTION_KEY = 'automation_action_key'.freeze
  TRANSIENT_METADATA_KEYS = [
    PROCESSING_CLAIM_KEY,
    DELIVERY_MATERIALIZED_MESSAGE_ID_KEY,
    DELIVERY_DISPATCHED_MESSAGE_ID_KEY,
    POST_DELIVERY_ACTION_MESSAGE_ID_KEY,
    POST_DELIVERY_ACTION_EXECUTED_AT_KEY
  ].freeze
  INTERNAL_METADATA_KEYS = (
    TRANSIENT_METADATA_KEYS + [
      POST_DELIVERY_AUDIT_SOURCE_KEY,
      POST_DELIVERY_AUTOMATION_RULE_ID_KEY,
      AUTOMATION_TRIGGER_MESSAGE_ID_KEY,
      AUTOMATION_ACTION_KEY
    ]
  ).freeze
  RELATIVE_TIME_MODE_INHERIT_ANCHOR_TIME = 'inherit_anchor_time'.freeze
  RELATIVE_TIME_MODE_FIXED_TIME_OF_DAY = 'fixed_time_of_day'.freeze
  RELATIVE_TIME_MODES = [
    RELATIVE_TIME_MODE_INHERIT_ANCHOR_TIME,
    RELATIVE_TIME_MODE_FIXED_TIME_OF_DAY
  ].freeze
  RELATIVE_TIME_OF_DAY_FORMAT = /\A(?:[01]\d|2[0-3]):[0-5]\d\z/
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

  has_one :confirmation_request, dependent: :nullify

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
  validates :relative_time_mode, inclusion: { in: RELATIVE_TIME_MODES }
  validates :relative_anchor, inclusion: { in: RELATIVE_ANCHORS }, allow_blank: true
  validates :post_delivery_action, inclusion: { in: POST_DELIVERY_ACTIONS }, allow_blank: true
  validates :response_action, inclusion: { in: RESPONSE_ACTIONS }, allow_blank: true
  validate :validate_account_matches
  validate :validate_target_associations
  validate :validate_json_field_shapes
  validate :validate_content_requirements
  validate :validate_delivery_policy
  validate :validate_repeat_requirements
  validate :validate_post_delivery_action
  validate :validate_response_action
  validate :validate_relative_time_of_day
  validate :validate_open_duplicate_absence

  before_validation :normalize_json_fields
  before_validation :preserve_internal_metadata
  before_validation :normalize_text_mode
  before_validation :sync_account_from_associations
  before_validation :hydrate_target_defaults
  before_validation :assign_owner_default, on: :create
  before_validation :normalize_repeat_fields
  before_validation :normalize_relative_time_fields
  before_validation :materialize_schedule
  before_validation :assign_default_status
  before_validation :refresh_fingerprint
  before_save :increment_schedule_revision, if: :will_save_change_to_scheduled_at?
  after_create :retain_attachment_blobs

  scope :ordered, -> { order(scheduled_at: :asc, created_at: :asc, id: :asc) }
  scope :open_statuses, -> { where(status: OPEN_STATUSES) }
  scope :due, -> { where('scheduled_at <= ?', Time.current) }

  def ready_for_pending?
    scheduled_at.present? && route_resolved? && content_ready?
  end

  def approve!
    return approve_unsaved! unless persisted?

    with_lock do
      reload
      next unless draft? || failed?

      raise_invalid_record! unless ready_for_pending?
      with_internal_metadata_write do
        update!(
          status: :pending,
          cancelled_at: nil,
          processing_started_at: nil,
          last_error: nil,
          metadata: metadata.to_h.except(*TRANSIENT_METADATA_KEYS)
        )
      end
    end
    self
  end

  def cancel!(reason = nil)
    return cancel_unsaved!(reason) unless persisted?

    with_lock do
      reload
      next unless OPEN_STATUSES.include?(status)
      next if delivery_materialized?

      update!(
        status: :cancelled,
        cancelled_at: Time.current,
        processing_started_at: nil,
        last_error: reason.presence || last_error
      )
    end
    self
  end

  def mark_processing!
    claim_token = SecureRandom.uuid
    claim_metadata = metadata.to_h.except(*TRANSIENT_METADATA_KEYS)
    with_internal_metadata_write do
      update!(
        status: :processing,
        processing_started_at: Time.current,
        last_error: nil,
        metadata: claim_metadata.merge(PROCESSING_CLAIM_KEY => claim_token)
      )
    end
    claim_token
  end

  def processing_claim_token
    metadata.to_h[PROCESSING_CLAIM_KEY].presence
  end

  def delivery_materialized?
    processing? && metadata.to_h[DELIVERY_MATERIALIZED_MESSAGE_ID_KEY].present?
  end

  def delivery_materialized_for?(message_id)
    metadata.to_h[DELIVERY_MATERIALIZED_MESSAGE_ID_KEY].to_s == message_id.to_s
  end

  def post_delivery_conversation
    return unless remindable.is_a?(Conversation)
    return unless conversation_id == remindable.id
    return unless target_conversation_id == remindable.id

    remindable
  end

  def mark_automation_provenance!(automation_rule, trigger_message: nil, action_key: nil)
    unless automation_rule.is_a?(AutomationRule) && automation_rule.account_id == account_id
      raise ArgumentError, 'Automation rule must belong to the reminder account'
    end

    validate_automation_trigger_message!(trigger_message)
    provenance = automation_provenance(automation_rule, trigger_message, action_key)

    with_internal_metadata_write do
      update!(metadata: metadata.to_h.merge(provenance))
    end
  end

  def mark_delivery_materialized!(message_id)
    with_internal_metadata_write do
      update!(metadata: metadata.to_h.merge(DELIVERY_MATERIALIZED_MESSAGE_ID_KEY => message_id))
    end
  end

  def delivery_dispatched_for?(message_id)
    metadata.to_h[DELIVERY_DISPATCHED_MESSAGE_ID_KEY].to_s == message_id.to_s
  end

  def mark_delivery_dispatched!(message_id)
    with_internal_metadata_write do
      update!(
        processing_started_at: nil,
        metadata: metadata.to_h.except(PROCESSING_CLAIM_KEY).merge(DELIVERY_DISPATCHED_MESSAGE_ID_KEY => message_id)
      )
    end
  end

  def post_delivery_action_executed_for?(message_id)
    metadata.to_h[POST_DELIVERY_ACTION_MESSAGE_ID_KEY].to_s == message_id.to_s
  end

  def mark_post_delivery_action_executed!(message_id)
    with_internal_metadata_write do
      update!(
        metadata: metadata.to_h.merge(
          POST_DELIVERY_ACTION_MESSAGE_ID_KEY => message_id,
          POST_DELIVERY_ACTION_EXECUTED_AT_KEY => Time.current.iso8601
        )
      )
    end
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

  def update_if_editable!
    updated = false
    with_lock do
      next unless editable?

      update!(yield)
      approve! if draft? && ready_for_pending?
      updated = true
    end
    updated
  end

  def destroy_if_allowed!
    destroyed = false
    with_lock do
      next unless destroyable?

      destroy!
      destroyed = true
    end
    destroyed
  end

  def editable?
    OPEN_STATUSES.include?(status) && !delivery_materialized?
  end

  def destroyable?
    draft? || pending? || failed? || cancelled?
  end

  def renderable_body(conversation: nil, sender: nil)
    render_text(body, conversation: conversation, sender: sender)
  end

  def renderable_template_params(conversation: nil, sender: nil)
    params = template_params.deep_stringify_keys
    return params if params['processed_params'].blank?

    params['processed_params'] = render_template_param_value(
      params['processed_params'],
      conversation: conversation,
      sender: sender
    )
    params
  end

  def recurring?
    !once?
  end

  def confirm_appointment_on_reply?
    response_action == RESPONSE_ACTION_CONFIRM_APPOINTMENT
  end

  def fixed_relative_time_of_day?
    relative_time_mode == RELATIVE_TIME_MODE_FIXED_TIME_OF_DAY
  end

  def relative_schedule_stale?
    return false unless relative? && !manual_schedule_override?

    current_anchor = relative_anchor_time
    return false if current_anchor.blank? && last_materialized_anchor_at.blank?

    current_anchor.blank? || last_materialized_anchor_at.blank? ||
      current_anchor.to_i != last_materialized_anchor_at.to_i
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

  def render_template_param_value(value, conversation:, sender:)
    case value
    when Hash
      value.transform_values { |item| render_template_param_value(item, conversation: conversation, sender: sender) }
    when Array
      value.map { |item| render_template_param_value(item, conversation: conversation, sender: sender) }
    when String
      render_text(value, conversation: conversation, sender: sender)
    else
      value
    end
  end

  def render_text(content, conversation:, sender:)
    Outbound::RenderedTextService.new(
      content: content,
      conversation: conversation || target_conversation || self.conversation,
      contact: target_contact || remindable.try(:contact),
      inbox: target_inbox,
      account: account,
      sender: sender || message_sender,
      appointment: appointment_context
    ).render
  end

  def appointment_context
    remindable if remindable.is_a?(Scheduling::Appointment)
  end

  def approve_unsaved!
    raise_invalid_record! unless ready_for_pending?

    update!(status: :pending, cancelled_at: nil, processing_started_at: nil, last_error: nil)
    self
  end

  def cancel_unsaved!(reason)
    update!(
      status: :cancelled,
      cancelled_at: Time.current,
      processing_started_at: nil,
      last_error: reason.presence || last_error
    )
    self
  end

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
                   remindable.owner || remindable.created_by
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
    return if manual_schedule_override?

    anchor_time = relative_anchor_time
    if anchor_time.blank?
      self.scheduled_at = nil
      self.status = :draft if status.blank? || pending?
      return
    end

    self.last_materialized_anchor_at = anchor_time
    self.scheduled_at = materialized_schedule_at(anchor_time)
  end

  def materialized_schedule_at(anchor_time)
    candidate = anchor_time + relative_offset_seconds.to_i.seconds
    return candidate unless fixed_relative_time_of_day?
    return candidate unless relative_time_of_day.to_s.match?(RELATIVE_TIME_OF_DAY_FORMAT)

    zone = Time.find_zone(timezone) || Time.zone
    hour, minute = relative_time_of_day.to_s.split(':').map(&:to_i)
    candidate_in_zone = candidate.in_time_zone(zone)
    zone.local(
      candidate_in_zone.year,
      candidate_in_zone.month,
      candidate_in_zone.day,
      hour,
      minute
    )
  end

  def normalize_relative_time_fields
    self.relative_time_mode = relative_time_mode.presence || RELATIVE_TIME_MODE_INHERIT_ANCHOR_TIME
    self.relative_time_of_day = relative_time_of_day.to_s.strip.presence
    self.relative_time_of_day = nil unless fixed_relative_time_of_day?
    self.manual_schedule_override = ActiveModel::Type::Boolean.new.cast(manual_schedule_override)
    self.schedule_revision = schedule_revision.to_i
  end

  def normalize_json_fields
    self.attachments = Array(attachments).compact
    self.template_params = (template_params || {}).to_h
    self.metadata = (metadata || {}).to_h
    self.post_delivery_action = post_delivery_action.presence
  end

  def preserve_internal_metadata
    return if @internal_metadata_write

    visible_metadata = metadata.to_h.except(*INTERNAL_METADATA_KEYS)
    stored_metadata = persisted? ? metadata_in_database.to_h.slice(*INTERNAL_METADATA_KEYS) : {}
    self.metadata = visible_metadata.merge(stored_metadata)
  end

  def with_internal_metadata_write
    previous_value = @internal_metadata_write
    @internal_metadata_write = true
    yield
  ensure
    @internal_metadata_write = previous_value
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
      timing_mode,
      relative_anchor,
      relative_offset_seconds,
      relative_time_mode,
      relative_time_of_day,
      content_kind,
      text_mode,
      post_delivery_action,
      response_fingerprint,
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
    when 'appointment.created_at', 'task.created_at', 'deal.created_at'
      remindable.try(:created_at)
    when 'appointment.starts_at'
      remindable.try(:starts_at)
    when 'appointment.ends_at'
      remindable.try(:ends_at)
    when 'task.due_at'
      remindable.try(:due_at)
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

  def automation_conversation_id
    target_conversation_id || conversation_id || (remindable_id if remindable_type == 'Conversation')
  end

  def automation_provenance(automation_rule, trigger_message, action_key)
    {
      POST_DELIVERY_AUTOMATION_RULE_ID_KEY => automation_rule.id,
      POST_DELIVERY_AUDIT_SOURCE_KEY => 'automation',
      AUTOMATION_TRIGGER_MESSAGE_ID_KEY => trigger_message&.id,
      AUTOMATION_ACTION_KEY => action_key.presence&.to_s
    }.compact
  end

  def validate_automation_trigger_message!(trigger_message)
    return if trigger_message.blank?
    return if trigger_message.account_id == account_id && trigger_message.conversation_id == automation_conversation_id

    raise ArgumentError, 'Automation trigger message must belong to the reminder conversation'
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

    return false if target_inbox_id.blank?
    return true if target_contact_inbox_id.present?
    return true if active_conversation_target?
    return false if target_contact.blank?

    Campaigns::TargetResolver.new(inbox: target_inbox, contact: target_contact).resolve.present?
  end

  def active_conversation_target?
    (target_conversation.present? && !target_conversation.resolved?) ||
      (conversation.present? && !conversation.resolved?)
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
    hydrate_from_current_entity_contact(
      contact: appointment.contact,
      conversation: appointment.conversation
    )
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
    hydrate_from_current_entity_contact(
      contact: deal.primary_contact || deal.contacts.first,
      conversation: deal.originating_conversation
    )
  end

  def hydrate_from_current_entity_contact(contact:, conversation:)
    return hydrate_from_conversation(conversation) if contact.blank?

    self.target_contact = contact
    self.target_inbox ||= conversation&.inbox
    clear_stale_contact_routes(contact)
    hydrate_from_conversation(conversation) if conversation&.contact_id == contact.id
  end

  def clear_stale_contact_routes(contact)
    self.conversation = nil if self.conversation&.contact_id != contact.id
    self.target_conversation = nil if target_conversation&.contact_id != contact.id
    self.target_contact_inbox = nil if target_contact_inbox&.contact_id != contact.id
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

  def validate_target_associations
    validate_consistent_target(:target_contact, target_contact_id, target_contact_inbox&.contact_id, target_conversation&.contact_id)
    validate_consistent_target(:target_inbox, target_inbox_id, target_contact_inbox&.inbox_id, target_conversation&.inbox_id)
    validate_consistent_target(:target_contact_inbox, target_contact_inbox_id, target_conversation&.contact_inbox_id)
  end

  def validate_consistent_target(attribute, *ids)
    return if ids.compact.uniq.length <= 1

    errors.add(attribute, 'must match the other target associations')
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
    elsif free_text? && template_params.present?
      errors.add(:template_params, 'must be blank for free-text touches')
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
    Campaigns::TemplateParamsValidator.validate!(inbox: target_inbox, template_params: template_params) if channel_template?
  rescue ArgumentError => e
    errors.add(:base, e.message)
  end

  def delivery_policy_ready_for_validation?
    return false if cancelled? || completed? || failed?
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

  def validate_post_delivery_action
    return if post_delivery_action.blank?

    errors.add(:post_delivery_action, 'is only supported for message touches') unless send_message?
    errors.add(:post_delivery_action, 'is only supported for one-time touches') unless once?
    errors.add(:post_delivery_action, 'is only supported for conversation touches') unless remindable.is_a?(Conversation)
    errors.add(:post_delivery_action, 'requires matching conversation references') if post_delivery_conversation.blank?
  end

  def validate_response_action
    return if response_action.blank? && response_button_index.blank?

    validate_response_action_shape
    validate_response_action_context
  end

  def validate_response_action_shape
    errors.add(:response_action, 'is only supported for appointment confirmations') unless confirm_appointment_on_reply?
    errors.add(:response_action, 'is only supported for message touches') unless send_message?
    errors.add(:response_action, 'is only supported for channel templates') unless channel_template?
    errors.add(:response_action, 'is only supported for one-time touches') unless once?
  end

  def validate_response_action_context
    errors.add(:response_action, 'is only supported for appointment touches') unless remindable.is_a?(Scheduling::Appointment)
    errors.add(:response_button_index, 'must be 0') unless response_button_index.to_s == '0'
    errors.add(:target_inbox, 'must be an official WhatsApp Cloud inbox') unless whatsapp_cloud_target?
    errors.add(:template_params, 'must select an approved template with exactly one quick-reply button') unless valid_confirmation_template?
  end

  def valid_confirmation_template?
    Reminders::ConfirmationTemplateValidator.new(
      account: account,
      inbox: target_inbox,
      template_params: template_params,
      button_index: response_button_index
    ).valid?
  end

  def response_fingerprint
    [response_action, response_button_index].join(':')
  end

  def whatsapp_cloud_target?
    target_inbox&.channel.is_a?(Channel::Whatsapp) && target_inbox.channel.provider == 'whatsapp_cloud'
  end

  def validate_relative_time_of_day
    return unless relative? && fixed_relative_time_of_day?

    if relative_time_of_day.blank?
      errors.add(:relative_time_of_day, 'must be present for fixed time of day relative touches')
      return
    end

    return if relative_time_of_day.match?(RELATIVE_TIME_OF_DAY_FORMAT)

    errors.add(:relative_time_of_day, 'must be in HH:MM format')
  end

  def increment_schedule_revision
    self.schedule_revision = schedule_revision.to_i + 1
  end

  def validate_open_duplicate_absence
    return if fingerprint.blank? || account_id.blank?
    return unless OPEN_STATUSES.include?(status)

    with_open_duplicate_lock do
      next unless open_duplicate_scope.exists?

      errors.add(:base, 'An open touch with the same content already exists')
    end
  end

  def with_open_duplicate_lock
    lock_key = Digest::SHA256.hexdigest("reminder-open-duplicate:#{account_id}:#{fingerprint}").first(16).to_i(16) % ((2**63) - 1)
    self.class.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key})")
    yield
  end

  # rubocop:disable Style/RaiseArgs
  def raise_invalid_record!
    raise ActiveRecord::RecordInvalid.new(self)
  end
  # rubocop:enable Style/RaiseArgs
end
# rubocop:enable Metrics/ClassLength
