# frozen_string_literal: true

# == Schema Information
#
# Table name: inboxes
#
#  id                            :integer          not null, primary key
#  allow_messages_after_resolved :boolean          default(TRUE)
#  auto_assignment_config        :jsonb
#  business_name                 :string
#  channel_type                  :string
#  csat_config                   :jsonb            not null
#  csat_survey_enabled           :boolean          default(FALSE)
#  deleting_at                   :datetime
#  email_address                 :string
#  enable_auto_assignment        :boolean          default(TRUE)
#  enable_email_collect          :boolean          default(TRUE)
#  greeting_enabled              :boolean          default(FALSE)
#  greeting_message              :string
#  lock_to_single_conversation   :boolean          default(FALSE), not null
#  name                          :string           not null
#  out_of_office_message         :string
#  sender_name_type              :integer          default("friendly"), not null
#  timezone                      :string           default("Asia/Almaty")
#  working_hours_enabled         :boolean          default(FALSE)
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
#  account_id                    :integer          not null
#  channel_id                    :integer          not null
#  portal_id                     :bigint
#
# Indexes
#
#  index_inboxes_on_account_id                   (account_id)
#  index_inboxes_on_account_id_and_deleting_at   (account_id,deleting_at)
#  index_inboxes_on_channel_id_and_channel_type  (channel_id,channel_type)
#  index_inboxes_on_portal_id                    (portal_id)
#
# Foreign Keys
#
#  fk_rails_...  (portal_id => portals.id)
#

class Inbox < ApplicationRecord
  include Reportable
  include Avatarable
  include OutOfOffisable
  include AccountCacheRevalidator
  include InboxAgentAvailability

  API_CHANNEL_TYPES = %w[Channel::Api].freeze
  DEFAULT_SINGLE_CONVERSATION_CHANNEL_TYPES = %w[
    Channel::FacebookPage
    Channel::Instagram
    Channel::Line

    Channel::Telegram
    Channel::TelegramPersonal
    Channel::Weixin
    Channel::Tiktok
    Channel::VkCommunity
    Channel::Whatsapp
    Channel::WhatsappWeb
  ].freeze

  # Not allowing characters:
  validates :name, presence: true
  validates :account_id, presence: true
  validates :timezone, inclusion: { in: TZInfo::Timezone.all_identifiers }
  validates :out_of_office_message, length: { maximum: Limits::OUT_OF_OFFICE_MESSAGE_MAX_LENGTH }
  validates :greeting_message, length: { maximum: Limits::GREETING_MESSAGE_MAX_LENGTH }
  validate :ensure_valid_max_assignment_limit

  belongs_to :account
  belongs_to :portal, optional: true

  belongs_to :channel, polymorphic: true, dependent: :destroy

  has_many :campaigns, dependent: :destroy_async
  has_many :campaign_audience_imports, dependent: :destroy_async
  has_many :campaign_deliveries, dependent: :delete_all
  has_many :lead_forms, dependent: :nullify
  has_many :lead_submissions, dependent: :nullify
  has_many :contact_channel_profiles, dependent: :destroy
  has_many :contact_inboxes, dependent: :destroy_async
  has_many :contacts, through: :contact_inboxes

  has_many :inbox_members, dependent: :destroy_async
  has_many :members, through: :inbox_members, source: :user
  has_many :conversations, dependent: :destroy_async
  has_many :messages, dependent: :destroy_async
  has_many :meta_ad_referrals, dependent: :delete_all
  has_many :telephony_call_sessions, class_name: 'Telephony::CallSession', dependent: :nullify

  has_one :inbox_assignment_policy, dependent: :destroy
  has_one :assignment_policy, through: :inbox_assignment_policy
  has_one :agent_bot_inbox, dependent: :destroy_async
  has_one :agent_bot, through: :agent_bot_inbox
  has_many :webhooks, dependent: :destroy_async
  has_many :hooks, dependent: :destroy_async, class_name: 'Integrations::Hook'

  enum sender_name_type: { friendly: 0, professional: 1 }

  before_validation :apply_single_conversation_default, on: :create
  after_create :add_account_members
  after_destroy :delete_round_robin_agents

  after_create_commit :dispatch_create_event
  after_update_commit :dispatch_update_event

  scope :active, -> { where(deleting_at: nil) }
  scope :order_by_name, -> { order('lower(name) ASC') }

  # Adds multiple members to the inbox
  # @param user_ids [Array<Integer>] Array of user IDs to add as members
  # @return [void]
  def add_members(user_ids)
    inbox_members.create!(user_ids.map { |user_id| { user_id: user_id } })
    update_account_cache
  end

  # Removes multiple members from the inbox
  # @param user_ids [Array<Integer>] Array of user IDs to remove
  # @return [void]
  def remove_members(user_ids)
    inbox_members.where(user_id: user_ids).destroy_all
    update_account_cache
  end

  # Sanitizes inbox name for balanced email provider compatibility
  # ALLOWS: /'._- and Unicode letters/numbers/emojis
  # REMOVES: Forbidden chars (\<>@"()) + spam-trigger symbols (!#$%&*+=?^`{|}~)
  def sanitized_name
    return default_name_for_blank_name if name.blank?

    sanitized = apply_sanitization_rules(name)
    sanitized.blank? && email? ? display_name_from_email : sanitized
  end

  def sanitized_business_name
    sanitize_raw_name(business_name) || sanitized_name
  end

  def sms?
    channel_type == 'Channel::Sms'
  end

  def facebook?
    channel_type == 'Channel::FacebookPage'
  end

  def instagram?
    (facebook? || instagram_direct?) && channel&.instagram_id.present?
  end

  def instagram_direct?
    channel_type == 'Channel::Instagram'
  end

  def tiktok?
    channel_type == 'Channel::Tiktok'
  end

  def web_widget?
    channel_type == 'Channel::WebWidget'
  end

  def api?
    API_CHANNEL_TYPES.include?(channel_type)
  end

  def whatsapp_web?
    channel_type == 'Channel::WhatsappWeb'
  end

  def email?
    channel_type == 'Channel::Email'
  end

  def twilio?
    channel_type == 'Channel::TwilioSms'
  end

  def twitter?
    channel_type == 'Channel::TwitterProfile'
  end

  def telegram?
    channel_type == 'Channel::Telegram'
  end

  def telegram_personal?
    channel_type == 'Channel::TelegramPersonal'
  end

  def weixin?
    channel_type == 'Channel::Weixin'
  end

  def vk_community?
    channel_type == 'Channel::VkCommunity'
  end

  def whatsapp?
    channel_type == 'Channel::Whatsapp'
  end

  def twilio_whatsapp?
    channel_type == 'Channel::TwilioSms' && channel&.medium == 'whatsapp'
  end

  # Legacy data can keep an inbox row after its channel row was deleted. Such an
  # inbox is still listed (so an administrator can delete it) instead of failing
  # every serializer that reads channel attributes.
  def channel_missing?
    channel.nil?
  end

  def lock_to_single_conversation=(value)
    @lock_to_single_conversation_explicitly_set = true
    super
  end

  def assignable_agents
    (account.users.where(id: members.select(:user_id)) + account.administrators).uniq
  end

  def active_bot?
    agent_bot_inbox&.active? || hooks.where(app_id: %w[dialogflow],
                                            status: 'enabled').count.positive?
  end

  def deleting?
    deleting_at.present?
  end

  def whatsapp_cloud_channel?
    channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
  end

  def pending_deletion_attempt?(attempt_id)
    deletion_intent_active?(attempt_id) &&
      (!whatsapp_cloud_channel? || channel.inbox_deletion_attempt_pending?(attempt_id))
  end

  def deletion_intent_active?(attempt_id)
    deleting? && attempt_id.present? && self[:deletion_attempt_id] == attempt_id
  end

  def deletion_recovery_payload
    channel.inbox_deletion_recovery_payload if whatsapp_cloud_channel?
  end

  def deletion_recovery_failed?
    !deleting? && self[:deletion_attempt_id].blank? && !account_deletion_requested? &&
      whatsapp_cloud_channel? && channel.inbox_deletion_failed?
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- keep generation and legacy deletion transitions atomic.
  def mark_pending_deletion!(timestamp: Time.current, attempt_id: nil)
    if deleting?
      if attempt_id.present?
        return self if self[:deletion_attempt_id].present? && self[:deletion_attempt_id] != attempt_id

        update!(deletion_attempt_id: attempt_id) if self[:deletion_attempt_id].blank?
        if whatsapp_cloud_channel? && channel.inbox_deletion_attempt_id.blank?
          channel.mark_inbox_deletion_pending!(attempt_id: attempt_id, requested_at: timestamp)
        end
      end
      return self
    end

    transaction do
      if channel_missing?
        # The required channel association cannot validate once its row is gone;
        # deleting such an inbox must still be possible.
        assign_attributes(deleting_at: timestamp, deletion_attempt_id: attempt_id)
        save!(validate: false)
        next
      end

      attempt_id ||= SecureRandom.uuid if whatsapp_cloud_channel?
      update!(deleting_at: timestamp, deletion_attempt_id: attempt_id)

      channel.mark_inbox_deletion_pending!(attempt_id: attempt_id, requested_at: timestamp) if whatsapp_cloud_channel?
      if (whatsapp_web? || telegram_personal? || weixin?) && channel.respond_to?(:mark_pending_deletion!)
        channel.mark_pending_deletion!(timestamp: timestamp)
      end
    end

    self
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def restore_after_whatsapp_deletion_failure!(attempt_id:)
    restored = false
    with_lock do
      reload
      next unless deletion_intent_active?(attempt_id) && whatsapp_cloud_channel? && channel.inbox_deletion_attempt_pending?(attempt_id)
      next if account_deletion_requested?
      next unless channel.mark_inbox_deletion_failed!(attempt_id: attempt_id, failed_at: Time.current)

      update!(deleting_at: nil, deletion_attempt_id: nil)
      restored = true
    end

    return false unless restored

    account.update_cache_key(self.class.name.underscore)
    true
  end

  def resolve_failed_whatsapp_deletion_recovery!
    resolved = false
    with_lock do
      reload
      next if deleting? || self[:deletion_attempt_id].present? || account_deletion_requested?
      next unless whatsapp_cloud_channel? && channel.inbox_deletion_failed?

      resolved = channel.resolve_inbox_deletion_recovery!
    end
    resolved
  end

  def inbox_type
    channel&.name || channel_type.to_s.demodulize
  end

  def display_channel_type
    return 'Channel::WhatsappWeb' if whatsapp_web?

    channel_type
  end

  def account_deletion_requested?
    account.reload.custom_attributes.to_h['marked_for_deletion_at'].present?
  end

  def webhook_data
    {
      id: id,
      name: name
    }
  end

  def callback_webhook_url
    return if channel_missing?

    case channel_type
    when 'Channel::TwilioSms'
      "#{ENV.fetch('FRONTEND_URL', nil)}/twilio/callback"
    when 'Channel::Sms'
      "#{ENV.fetch('FRONTEND_URL', nil)}/webhooks/sms/#{channel.phone_number.delete_prefix('+')}"
    when 'Channel::Line'
      "#{ENV.fetch('FRONTEND_URL', nil)}/webhooks/line/#{channel.line_channel_id}"
    when 'Channel::TelegramPersonal', 'Channel::Weixin', 'Channel::Whatsapp', 'Channel::VkCommunity'
      channel.callback_webhook_url
    end
  end

  def member_ids_with_assignment_capacity
    members.ids
  end

  def auto_assignment_v2_enabled?
    account.feature_enabled?('assignment_v2')
  end

  private

  def add_account_members
    # Serialize both creation paths without conflicting with their account foreign-key locks.
    account.with_lock('FOR NO KEY UPDATE') do
      next if deleting? || self[:deletion_attempt_id].present? || account_deletion_requested?

      account.users.ids.each { |user_id| inbox_members.find_or_create_by!(user_id: user_id) }
    end
  end

  def default_name_for_blank_name
    email? ? display_name_from_email : ''
  end

  def sanitize_raw_name(raw_name)
    return nil if raw_name.blank?

    apply_sanitization_rules(raw_name).presence
  end

  def apply_sanitization_rules(name)
    name.gsub(/[\\<>@"!#$%&*+=?^`{|}~:;()]/, '')        # Remove forbidden chars
        .gsub(/[\x00-\x1F\x7F]/, ' ')                   # Replace control chars with spaces
        .gsub(/\A[[:punct:]]+|[[:punct:]]+\z/, '')      # Remove leading/trailing punctuation
        .gsub(/\s+/, ' ')                               # Normalize spaces
        .strip
  end

  def display_name_from_email
    channel.email.split('@').first.parameterize.titleize
  end

  def dispatch_create_event
    return if ENV['ENABLE_INBOX_EVENTS'].blank?

    Rails.configuration.dispatcher.dispatch(INBOX_CREATED, Time.zone.now, inbox: self)
  end

  def dispatch_update_event
    return if ENV['ENABLE_INBOX_EVENTS'].blank?

    Rails.configuration.dispatcher.dispatch(INBOX_UPDATED, Time.zone.now, inbox: self, changed_attributes: previous_changes)
  end

  def apply_single_conversation_default
    return if @lock_to_single_conversation_explicitly_set

    self.lock_to_single_conversation = default_single_conversation_for_channel?
  end

  def default_single_conversation_for_channel?
    return true if DEFAULT_SINGLE_CONVERSATION_CHANNEL_TYPES.include?(resolved_channel_type)
    return true if channel.is_a?(Channel::TwilioSms) && channel.whatsapp?

    false
  end

  def resolved_channel_type
    channel_type.presence || channel&.class&.name
  end

  def ensure_valid_max_assignment_limit
    # overridden in enterprise/app/models/enterprise/inbox.rb
  end

  def delete_round_robin_agents
    ::AutoAssignment::InboxRoundRobinService.new(inbox: self).clear_queue
  end

  def check_channel_type?
    ['Channel::Email', 'Channel::WebWidget', *API_CHANNEL_TYPES].include?(channel_type)
  end
end

Inbox.prepend_mod_with('Inbox')
Inbox.include_mod_with('Audit::Inbox')
Inbox.include_mod_with('Concerns::Inbox')
