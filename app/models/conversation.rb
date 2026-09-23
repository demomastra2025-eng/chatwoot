# == Schema Information
#
# Table name: conversations
#
#  id                     :integer          not null, primary key
#  additional_attributes  :jsonb
#  agent_last_seen_at     :datetime
#  assignee_last_seen_at  :datetime
#  cached_label_list      :text
#  contact_last_seen_at   :datetime
#  custom_attributes      :jsonb
#  first_reply_created_at :datetime
#  identifier             :string
#  identity_key           :string
#  last_activity_at       :datetime         not null
#  priority               :integer
#  snoozed_until          :datetime
#  status                 :integer          default("open"), not null
#  uuid                   :uuid             not null
#  waiting_since          :datetime
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :integer          not null
#  assignee_agent_bot_id  :bigint
#  assignee_id            :integer
#  campaign_id            :bigint
#  contact_id             :bigint
#  contact_inbox_id       :bigint
#  display_id             :integer          not null
#  inbox_id               :integer          not null
#  sla_policy_id          :bigint
#  team_id                :bigint
#
# Indexes
#
#  conv_acid_inbid_stat_asgnid_idx                    (account_id,inbox_id,status,assignee_id)
#  index_conversations_on_account_id                  (account_id)
#  index_conversations_on_account_id_and_display_id   (account_id,display_id) UNIQUE
#  index_conversations_on_assignee_id_and_account_id  (assignee_id,account_id)
#  index_conversations_on_campaign_id                 (campaign_id)
#  index_conversations_on_contact_id                  (contact_id)
#  index_conversations_on_contact_inbox_id            (contact_inbox_id)
#  index_conversations_on_first_reply_created_at      (first_reply_created_at)
#  index_conversations_on_id_and_account_id           (account_id,id)
#  index_conversations_on_identifier_and_account_id   (identifier,account_id)
#  idx_conversations_on_account_inbox_contact_identity (account_id,inbox_id,contact_id,identity_key) WHERE (identity_key IS NOT NULL)
#  index_conversations_on_inbox_id                    (inbox_id)
#  index_conversations_on_priority                    (priority)
#  index_conversations_on_status_and_account_id       (status,account_id)
#  index_conversations_on_status_and_priority         (status,priority)
#  index_conversations_on_team_id                     (team_id)
#  index_conversations_on_uuid                        (uuid) UNIQUE
#  index_conversations_on_waiting_since               (waiting_since)
#

class Conversation < ApplicationRecord
  include Labelable
  include LlmFormattable
  include AssignmentHandler
  include AutoAssignmentHandler
  include ActivityMessageHandler
  include UrlHelper
  include SortHandler
  include PushDataHelper
  include ConversationMuteHelpers

  attr_accessor :skip_runtime_events, :skip_communication_thread_refresh, :skip_communication_thread_realtime,
                :communication_thread_event_id, :communication_thread_event_actor,
                :communication_thread_event_source, :communication_thread_event_source_record,
                :communication_thread_event_occurred_at

  validates :account_id, presence: true
  validates :inbox_id, presence: true
  validates :contact_id, presence: true
  before_validation :validate_additional_attributes
  before_validation :inherit_contact_owner, on: :create

  validates :additional_attributes, jsonb_attributes_length: true
  validates :custom_attributes, jsonb_attributes_length: true
  validates :identity_key, length: { maximum: 255 }, allow_nil: true
  validates :uuid, uniqueness: true
  validate :validate_referer_url

  enum status: { open: 0, resolved: 1, pending: 2, snoozed: 3 }
  enum priority: { low: 0, medium: 1, high: 2, urgent: 3 }

  scope :unassigned, -> { where(assignee_id: nil) }
  scope :assigned, -> { where.not(assignee_id: nil) }
  scope :assigned_to, ->(agent) { where(assignee_id: agent.id) }
  scope :unattended, -> { where(first_reply_created_at: nil).or(where.not(waiting_since: nil)) }
  scope :resolvable_not_waiting, lambda { |auto_resolve_after|
    return none if auto_resolve_after.to_i.zero?

    open.where('last_activity_at < ? AND waiting_since IS NULL', Time.now.utc - auto_resolve_after.minutes)
  }
  scope :resolvable_all, lambda { |auto_resolve_after|
    return none if auto_resolve_after.to_i.zero?

    open.where('last_activity_at < ?', Time.now.utc - auto_resolve_after.minutes)
  }

  scope :last_user_message_at, lambda {
    joins(
      "INNER JOIN (#{last_messaged_conversations.to_sql}) AS grouped_conversations
      ON grouped_conversations.conversation_id = conversations.id"
    ).sort_on_last_user_message_at
  }

  belongs_to :account
  belongs_to :inbox
  belongs_to :assignee, class_name: 'User', optional: true, inverse_of: :assigned_conversations

  belongs_to :contact
  belongs_to :contact_inbox
  belongs_to :team, optional: true
  belongs_to :campaign, optional: true

  has_many :mentions, dependent: :destroy_async
  has_many :messages, dependent: :destroy_async, autosave: true
  has_many :meta_ad_referrals, dependent: :nullify
  has_many :status_transitions, class_name: 'ConversationStatusTransition', dependent: :destroy_async
  has_many :telephony_call_sessions, class_name: 'Telephony::CallSession', dependent: :nullify
  has_one :csat_survey_response, dependent: :destroy_async
  has_many :conversation_participants, dependent: :destroy_async
  has_many :conversation_user_read_states, dependent: :delete_all
  has_many :notifications, as: :primary_actor, dependent: :destroy_async
  has_many :attachments, through: :messages
  has_many :reporting_events, dependent: :destroy_async
  has_many :reminders, as: :remindable, dependent: :nullify
  has_one :communication_thread_conversation, dependent: :destroy
  has_one :communication_thread, through: :communication_thread_conversation

  before_save :ensure_snooze_until_reset
  before_create :determine_conversation_status
  before_create :ensure_waiting_since

  after_create :capture_automation_create_event
  after_create :sync_contact_owner_from_assignee
  after_create :ensure_communication_thread, if: :communication_threads_enabled?
  before_update :lock_contact_before_assignee_change, if: :will_save_change_to_assignee_id?
  before_update :lock_routing_team_before_change, if: :routing_team_lock_required?
  before_update :lock_contact_conversations_before_assignee_change, if: :will_save_change_to_assignee_id?
  after_update :capture_automation_updated_changes_for_commit
  after_update :sync_contact_owner_from_assignee
  after_update :ensure_communication_thread, if: :communication_thread_refresh_required?
  after_save :clear_communication_thread_event_context_after_save
  before_commit :capture_automation_update_events, on: :update
  after_update_commit :execute_after_update_commit_callbacks
  after_create_commit :notify_conversation_creation
  after_create_commit :load_attributes_created_by_db_triggers
  after_create_commit :auto_create_crm_deal_from_channel_contact
  after_commit :clear_automation_updated_changes
  after_rollback :clear_automation_updated_changes
  after_rollback :clear_communication_thread_event_context_on_rollback

  attr_reader :last_saved_communication_thread_event_id

  delegate :auto_resolve_after, to: :account

  def can_reply?
    return false if inbox.blank?

    Conversations::MessageWindowService.new(self).can_reply?
  end

  def language
    additional_attributes&.dig('conversation_language')
  end

  # Be aware: The precision of created_at and last_activity_at may differ from Ruby's Time precision.
  # Our DB column (see schema) stores timestamps with second-level precision (no microseconds), so
  # if you assign a Ruby Time with microseconds, the DB will truncate it. This may cause subtle differences
  # if you compare or copy these values in Ruby, also in our specs
  # So in specs rely on to be_with(1.second) instead of to eq()
  # TODO: Migrate to use a timestamp with microsecond precision
  def last_activity_at
    self[:last_activity_at] || created_at
  end

  def last_incoming_message
    messages.where(account_id: account_id)&.incoming&.last
  end

  def toggle_status
    Conversations::StatusTransitionService.new(
      conversation: self,
      actor: Current.user || Current.executed_by,
      source: 'system'
    ).perform
  end

  def toggle_priority(priority = nil)
    self.priority = priority.presence
    save
  end

  def bot_handoff!(status_reason: nil, actor: Current.user || Current.executed_by, source: 'system', audit: {})
    self.waiting_since = Time.current if waiting_since.blank?
    Conversations::StatusTransitionService.new(
      conversation: self,
      params: { status: 'open', status_reason: status_reason }.compact,
      actor: actor,
      source: source,
      audit: audit
    ).perform
    dispatcher_dispatch(CONVERSATION_BOT_HANDOFF)
  end

  def unread_messages
    scope = agent_last_seen_at.present? ? messages.created_since(agent_last_seen_at) : messages
    scope.without_imported_history
  end

  def last_seen_at_for(user)
    read_state = conversation_user_read_states.find_by(user_id: user.id)
    read_state ? read_state.last_seen_at : agent_last_seen_at
  end

  def unread_messages_for(user)
    last_seen_at = last_seen_at_for(user)
    scope = last_seen_at.present? ? messages.created_since(last_seen_at) : messages
    scope.without_imported_history
  end

  def assignee_unread_messages
    scope = assignee_last_seen_at.present? ? messages.created_since(assignee_last_seen_at) : messages
    scope.without_imported_history
  end

  def unread_incoming_messages
    unread_incoming_message_scope.last(10)
  end

  def unread_incoming_messages_count
    unread_incoming_message_scope.count
  end

  def cached_label_list_array
    (cached_label_list || '').split(',').map(&:strip)
  end

  def notifiable_assignee_change?
    return false unless saved_change_to_assignee_id?
    return false if assignee_id.blank?
    return false if self_assign?(assignee_id)

    true
  end

  def assignee_type
    return 'User' if assignee_id.present?

    nil
  end

  def assigned_entity
    assignee
  end

  def tweet?
    inbox.inbox_type == 'Twitter' && additional_attributes['type'] == 'tweet'
  end

  def recent_messages
    messages.chat.last(5)
  end

  def csat_survey_link
    "#{ENV.fetch('FRONTEND_URL', nil)}/survey/responses/#{uuid}"
  end

  def dispatch_conversation_updated_event(previous_changes = nil)
    dispatcher_dispatch(CONVERSATION_UPDATED, previous_changes)
  end

  def communication_thread
    thread = super
    return if thread.blank?
    return thread if thread.account_id == account_id && thread.contact_id == contact_id
  end

  def refresh_communication_thread!
    return unless communication_threads_enabled?

    Conversations::CommunicationThreadResolver.new(conversation: self).perform
  end

  def clear_communication_thread_event_context!
    self.communication_thread_event_id = nil
    self.communication_thread_event_actor = nil
    self.communication_thread_event_source = nil
    self.communication_thread_event_source_record = nil
    self.communication_thread_event_occurred_at = nil
    self.skip_communication_thread_refresh = false
  end

  private

  def ensure_communication_thread
    refresh_communication_thread!
  end

  def auto_create_crm_deal_from_channel_contact
    return if runtime_events_suppressed?
    return if contact_inbox.blank?

    ::Crm::Deals::AutoCreateFromChannelContactService.new(
      contact_inbox: contact_inbox,
      conversation: self
    ).perform
  end

  def communication_threads_enabled?
    account&.feature_enabled?('communication_threads')
  end

  def communication_thread_refresh_required?
    communication_threads_enabled? && !skip_communication_thread_refresh
  end

  def unread_incoming_message_scope
    unread_messages.where(account_id: account_id, private: false).incoming
  end

  def execute_after_update_commit_callbacks
    handle_resolved_status_change
    runtime_events_suppressed = runtime_events_suppressed?
    notify_status_change unless runtime_events_suppressed
    return if runtime_events_suppressed

    notify_ai_transfer
    create_activity
    notify_conversation_updation
  ensure
    @last_saved_communication_thread_event_id = nil
  end

  def clear_communication_thread_event_context_after_save
    @last_saved_communication_thread_event_id = communication_thread_event_id
    clear_communication_thread_event_context!
  end

  def clear_communication_thread_event_context_on_rollback
    clear_communication_thread_event_context_after_save
    @last_saved_communication_thread_event_id = nil
  end

  def handle_resolved_status_change
    # When conversation is resolved, clear waiting_since using update_column to avoid callbacks
    return unless saved_change_to_status? && status == 'resolved'

    # rubocop:disable Rails/SkipsModelValidations
    update_column(:waiting_since, nil)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def ensure_snooze_until_reset
    self.snoozed_until = nil unless snoozed?
  end

  def ensure_waiting_since
    self.waiting_since = created_at
  end

  def validate_additional_attributes
    self.additional_attributes = {} unless additional_attributes.is_a?(Hash)
  end

  def inherit_contact_owner
    return if assignee_id.present?
    return if contact&.owner.blank?

    self.assignee = contact.owner
  end

  def sync_contact_owner_from_assignee
    return unless saved_change_to_assignee_id?
    return if contact_owner_synced?
    return unless contact_owner_sync_allowed?

    unless communication_threads_enabled?
      contact.update!(owner_id: assignee_id)
      return
    end

    # Contact still fans out to the other channels, but the Thread fact must
    # reflect this Conversation's final status after its resolver callback.
    previous_defer = contact.defer_communication_thread_owner_fact
    begin
      contact.defer_communication_thread_owner_fact = true
      contact.update!(owner_id: assignee_id)
    ensure
      contact.defer_communication_thread_owner_fact = previous_defer
    end
  end

  def lock_contact_before_assignee_change
    contact&.lock!
  end

  def lock_contact_conversations_before_assignee_change
    # Owner fan-out locks Contact, then the target Team, then every channel in
    # id order before the first Conversation UPDATE takes this row's lock.
    return if contact_owner_synced? || !contact_owner_sync_allowed?

    self.class.where(account_id: account_id, contact_id: contact_id).order(:id).lock.load
  end

  def routing_team_lock_required?
    will_save_change_to_team_id? || will_save_change_to_assignee_id?
  end

  def lock_routing_team_before_change
    ids = [team_id] if will_save_change_to_team_id?
    ids ||= []
    if will_save_change_to_assignee_id? && !contact_owner_synced? && contact_owner_sync_allowed? && assignee_id.present?
      ids.concat(TeamMember.joins(:team).where(user_id: assignee_id, teams: { account_id: account_id }).pluck(:team_id))
    end
    Team.lock_routing_targets!(account_id: account_id, team_ids: ids)
  end

  def contact_owner_synced?
    contact.blank? || contact.owner_id == assignee_id
  end

  def contact_owner_sync_allowed?
    return false if auto_assignment_fallback_for_existing_owner?
    return true if assignee_id.blank?

    account.users.exists?(id: assignee_id)
  end

  def auto_assignment_fallback_for_existing_owner?
    contact&.owner_id.present? && (Current.executed_by.is_a?(AssignmentPolicy) || Current.executed_by.is_a?(Inbox))
  end

  def determine_conversation_status
    self.status = :resolved and return if contact.blocked?

    return if outbound_campaign_conversation? && resolved?

    return handle_campaign_status if campaign.present?

    # TODO: make this an inbox config instead of assuming bot conversations should start as pending
    self.status = :pending if inbox.active_bot?
  end

  def handle_campaign_status
    return if outbound_campaign_conversation? && resolved?

    # If campaign has no sender (bot-initiated) and inbox has active bot, let bot handle it
    self.status = :pending if campaign.sender_id.nil? && campaign.captain_assistant_id.nil? && inbox.active_bot?
  end

  def outbound_campaign_conversation?
    additional_attributes&.dig('outbound_campaign_id').present? || additional_attributes&.dig(:outbound_campaign_id).present?
  end

  def notify_conversation_creation
    return if runtime_events_suppressed?

    dispatcher_dispatch(CONVERSATION_CREATED)
  end

  def capture_automation_create_event
    @automation_create_occurrence_id ||= SecureRandom.uuid
    capture_automation_event(CONVERSATION_CREATED, {}, @automation_create_occurrence_id)
  end

  def capture_automation_update_events
    return if runtime_events_suppressed?

    changed_attributes = automation_updated_changes
    return if changed_attributes.blank?

    @automation_update_occurrence_id ||= SecureRandom.uuid
    capture_automation_status_events(changed_attributes)
    if ai_transfer_state_entered?(changed_attributes)
      capture_automation_event(
        CONVERSATION_TRANSFERRED_TO_AI,
        { 'status' => changed_attributes['status'] },
        @automation_update_occurrence_id
      )
    end
    return unless automation_allowed_keys?(changed_attributes)

    capture_automation_event(CONVERSATION_UPDATED, changed_attributes, @automation_update_occurrence_id)
  end

  def capture_automation_status_events(changed_attributes)
    status_change = changed_attributes['status']
    return if status_change.blank?

    changes = { 'status' => status_change }
    capture_automation_event(CONVERSATION_OPENED, changes, @automation_update_occurrence_id) if open?
    capture_automation_event(CONVERSATION_RESOLVED, changes, @automation_update_occurrence_id) if resolved?
    capture_automation_event(CONVERSATION_PENDING, changes, @automation_update_occurrence_id) if pending?
  end

  def capture_automation_event(event_name, changed_attributes, occurrence_id)
    return if runtime_events_suppressed?

    AutomationRules::Events::CaptureService.capture_model_event!(
      record: self,
      event_name: event_name,
      payload_snapshot: AutomationRules::Events::MatchingSnapshot.for(self),
      changes_snapshot: changed_attributes || {},
      producer: 'conversation_model',
      occurrence_id: occurrence_id
    )
  end

  def capture_automation_updated_changes_for_commit
    @automation_updated_changes ||= {}
    saved_changes.each do |attribute, (previous_value, current_value)|
      original_value = @automation_updated_changes.key?(attribute) ? @automation_updated_changes.dig(attribute, 0) : previous_value
      @automation_updated_changes[attribute] = [original_value, current_value]
    end
  end

  def automation_updated_changes
    (@automation_updated_changes.presence || previous_changes).except('updated_at', :updated_at)
  end

  def clear_automation_updated_changes
    @automation_updated_changes = nil
    @automation_update_occurrence_id = nil
    @automation_create_occurrence_id = nil
  end

  def notify_conversation_updation
    return if runtime_events_suppressed?
    return unless previous_changes.keys.present? && allowed_keys?

    dispatch_conversation_updated_event(previous_changes)
  end

  def list_of_keys
    %w[team_id assignee_id status snoozed_until custom_attributes label_list waiting_since
       first_reply_created_at priority]
  end

  def allowed_keys?
    (
      previous_changes.keys.intersect?(list_of_keys) ||
      (previous_changes['additional_attributes'].present? && previous_changes['additional_attributes'][1].keys.intersect?(%w[conversation_language]))
    )
  end

  def automation_allowed_keys?(changes)
    return true if changes.keys.intersect?(list_of_keys)

    additional_attributes = changes['additional_attributes']
    additional_attributes.is_a?(Array) && additional_attributes[1].is_a?(Hash) &&
      additional_attributes[1].keys.intersect?(%w[conversation_language call_status])
  end

  def load_attributes_created_by_db_triggers
    # Display id is set via a trigger in the database
    # So we need to specifically fetch it after the record is created
    # We can't use reload because it will clear the previous changes, which we need for the dispatcher
    obj_from_db = self.class.find(id)
    self[:display_id] = obj_from_db[:display_id]
    self[:uuid] = obj_from_db[:uuid]
  end

  def runtime_events_suppressed?
    skip_runtime_events || Current.suppress_runtime_events
  end

  def notify_status_change
    {
      CONVERSATION_OPENED => -> { saved_change_to_status? && open? },
      CONVERSATION_RESOLVED => -> { saved_change_to_status? && resolved? },
      CONVERSATION_PENDING => -> { saved_change_to_status? && pending? },
      CONVERSATION_STATUS_CHANGED => -> { saved_change_to_status? },
      CONVERSATION_READ => -> { saved_change_to_contact_last_seen_at? },
      CONVERSATION_CONTACT_CHANGED => -> { saved_change_to_contact_id? }
    }.each do |event, condition|
      condition.call && dispatcher_dispatch(event, status_change)
    end
  end

  def notify_ai_transfer
    return unless ai_transfer_state_entered?

    dispatcher_dispatch(CONVERSATION_TRANSFERRED_TO_AI, ai_transfer_changed_attributes)
  end

  def ai_transfer_state_entered?(changes = previous_changes)
    ai_pending_state_entered?(changes)
  end

  def ai_pending_state_entered?(changes = previous_changes)
    changes['status'].present? && pending? && ai_pending_handler_present?
  end

  def ai_pending_handler_present?
    inbox_active_bot? || inbox_captain_assistant_present?
  end

  def inbox_active_bot?
    inbox.respond_to?(:active_bot?) && inbox.active_bot?
  end

  def inbox_captain_assistant_present?
    return false unless Object.const_defined?('CaptainInbox')

    CaptainInbox.exists?(inbox_id: inbox_id)
  end

  def ai_transfer_changed_attributes
    ai_pending_state_entered? ? status_change : previous_changes
  end

  def dispatcher_dispatch(event_name, changed_attributes = nil)
    Rails.configuration.dispatcher.dispatch(event_name, Time.zone.now, conversation: self, notifiable_assignee_change: notifiable_assignee_change?,
                                                                       changed_attributes: changed_attributes,
                                                                       performed_by: Current.executed_by)
  end

  def conversation_status_changed_to_open?
    return false unless open?
    # saved_change_to_status? method only works in case of update
    return true if previous_changes.key?(:id) || saved_change_to_status?
  end

  def create_label_change(user_name)
    return unless user_name

    previous_labels, current_labels = previous_changes[:label_list]
    return unless (previous_labels.is_a? Array) && (current_labels.is_a? Array)

    create_label_added(user_name, current_labels - previous_labels)
    create_label_removed(user_name, previous_labels - current_labels)
  end

  def validate_referer_url
    return unless additional_attributes['referer']

    self['additional_attributes']['referer'] = nil unless url_valid?(additional_attributes['referer'])
  end

  # creating db triggers
  trigger.before(:insert).for_each(:row) do
    "NEW.display_id := nextval('conv_dpid_seq_' || NEW.account_id);"
  end
end

Conversation.include_mod_with('Audit::Conversation')
Conversation.include_mod_with('Concerns::Conversation')
Conversation.prepend_mod_with('Conversation')
