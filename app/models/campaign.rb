# == Schema Information
#
# Table name: campaigns
#
#  id                                 :bigint           not null, primary key
#  audience                           :jsonb
#  campaign_status                    :integer          default("active"), not null
#  campaign_type                      :integer          default("ongoing"), not null
#  description                        :text
#  enabled                            :boolean          default(TRUE)
#  idempotency_fingerprint            :string
#  idempotency_key                    :string
#  instructions                       :text
#  launch_requested_at                :datetime
#  message                            :text             not null
#  scheduled_at                       :datetime
#  template_params                    :jsonb
#  text_mode                          :integer          default("static"), not null
#  title                              :string           not null
#  trigger_only_during_business_hours :boolean          default(FALSE)
#  trigger_rules                      :jsonb
#  created_at                         :datetime         not null
#  updated_at                         :datetime         not null
#  account_id                         :bigint           not null
#  campaign_audience_import_id        :bigint
#  captain_assistant_id               :bigint
#  display_id                         :integer          not null
#  inbox_id                           :bigint           not null
#  sender_id                          :integer
#
# Indexes
#
#  idx_campaigns_on_audience_import                   (campaign_audience_import_id) UNIQUE
#  index_campaigns_on_account_id                      (account_id)
#  index_campaigns_on_account_id_and_idempotency_key  (account_id,idempotency_key) UNIQUE WHERE (idempotency_key IS NOT NULL)
#  index_campaigns_on_campaign_status                 (campaign_status)
#  index_campaigns_on_campaign_type                   (campaign_type)
#  index_campaigns_on_captain_assistant_id            (captain_assistant_id)
#  index_campaigns_on_inbox_id                        (inbox_id)
#  index_campaigns_on_launch_requested_at             (launch_requested_at)
#  index_campaigns_on_scheduled_at                    (scheduled_at)
#
# Foreign Keys
#
#  fk_rails_...  (campaign_audience_import_id => campaign_audience_imports.id) ON DELETE => nullify
#  fk_rails_...  (captain_assistant_id => captain_assistants.id)
#
class Campaign < ApplicationRecord
  include UrlHelper
  LAUNCH_REQUEST_LEASE = 10.minutes
  ONE_OFF_INBOX_TYPES = ['Twilio SMS', 'Sms', 'Whatsapp', 'Email', 'WhatsApp Web', 'Telegram', 'Telegram Personal', 'VK', 'LINE', 'Facebook',
                         'Instagram', 'Tiktok', 'Twitter'].freeze
  SUPPORTED_INBOX_TYPES = ['Website', *ONE_OFF_INBOX_TYPES].freeze

  validates :account_id, presence: true
  validates :inbox_id, presence: true
  validates :title, presence: true
  validates :message, presence: true, unless: :agent?
  validates :instructions, presence: true, if: :agent?
  validates :idempotency_fingerprint, length: { is: 64 }, allow_nil: true
  validates :idempotency_key, length: { maximum: 128 }, uniqueness: { scope: :account_id }, allow_nil: true
  validate :validate_campaign_inbox
  validate :validate_url
  validate :prevent_terminal_campaign_from_update, on: :update
  validate :sender_must_belong_to_account
  validate :captain_assistant_must_belong_to_account
  validate :captain_assistant_must_be_connected_to_inbox
  validate :inbox_must_belong_to_account
  validate :validate_ai_authoring_availability
  validate :validate_official_whatsapp_delivery_policy
  validate :audience_import_matches_campaign

  belongs_to :account
  belongs_to :inbox
  belongs_to :sender, class_name: 'User', optional: true
  belongs_to :captain_assistant, class_name: 'Captain::Assistant', optional: true
  belongs_to :campaign_audience_import, optional: true

  enum campaign_type: { ongoing: 0, one_off: 1 }
  # TODO : enabled attribute is unneccessary . lets move that to the campaign status with additional statuses like draft, disabled etc.
  enum campaign_status: { active: 0, completed: 1, running: 2, failed: 3, cancelled: 4 }
  enum text_mode: { static: 0, dynamic: 1, agent: 2 }

  has_many :conversations, dependent: :nullify, autosave: true
  has_many :campaign_deliveries, dependent: :delete_all
  has_many :campaign_runs, dependent: :delete_all

  def latest_campaign_run
    return @latest_campaign_run if defined?(@latest_campaign_run)

    @latest_campaign_run = if association(:campaign_runs).loaded?
                             campaign_runs.max_by(&:created_at)
                           else
                             campaign_runs.order(created_at: :desc).first
                           end
  end

  before_validation :normalize_text_mode
  before_validation :assign_captain_assistant_from_inbox
  before_validation :ensure_correct_campaign_attributes
  after_commit :set_display_id, unless: :display_id?
  after_destroy_commit :enqueue_audience_import_cleanup

  def trigger!
    return unless one_off?
    return unless mark_running_if_active!

    execute_campaign
  rescue StandardError
    with_lock do
      reload
      failed! if active? || running?
    end
    raise
  end

  def request_one_off_launch!(requested_at: Time.current)
    with_lock do
      reload
      next false unless one_off? && active?
      next false if launch_requested_at.present? && launch_requested_at >= requested_at - LAUNCH_REQUEST_LEASE

      update!(launch_requested_at: requested_at)
      true
    end
  end

  def release_one_off_launch!(requested_at:)
    with_lock do
      reload
      matching_request = launch_requested_at.present? && (launch_requested_at.to_f - requested_at.to_f).abs < 0.001
      next false unless active? && matching_request

      update!(launch_requested_at: nil)
      true
    end
  end

  def cancel_one_off!
    with_lock do
      reload

      unless one_off? && (active? || running?)
        errors.add(:campaign_status, 'cannot be cancelled in its current state')
        raise ActiveRecord::RecordInvalid, self
      end

      latest_campaign_run&.cancel! if running? && latest_campaign_run&.running?
      cancelled!
    end
  end

  def sync_status_from_run!(run)
    return unless one_off? && run.present?

    with_lock do
      reload

      latest_run_id = campaign_runs.order(created_at: :desc).limit(1).pick(:id)
      next unless latest_run_id == run.id

      next_status = case run.status
                    when 'running' then :running
                    when 'cancelled' then :cancelled
                    when 'failed' then :failed
                    when 'completed' then :completed
                    end

      next if next_status.blank? || campaign_status == next_status.to_s

      update_column(:campaign_status, self.class.campaign_statuses.fetch(next_status.to_s))
    end
  end

  private

  def enqueue_audience_import_cleanup
    return if campaign_audience_import_id.blank?

    Campaigns::AudienceImportCleanupJob.perform_later(campaign_audience_import_id)
  rescue StandardError => e
    Rails.logger.error("[CAMPAIGN AUDIENCE IMPORT] import=#{campaign_audience_import_id} cleanup enqueue failed: #{e.class}")
    false
  end

  def normalize_text_mode
    self.text_mode = Reminders::TextModeResolver.call(
      action_type: 'send_message',
      body: message,
      instructions: instructions,
      text_mode: text_mode
    )
  end

  def mark_running_if_active!
    with_lock do
      reload
      next false unless active?

      update!(campaign_status: :running, launch_requested_at: nil)
      true
    end
  end

  def execute_campaign
    Campaigns::OneoffRunner.new(campaign: self).perform
  end

  def set_display_id
    reload
  end

  def validate_campaign_inbox
    return unless inbox

    errors.add :inbox, 'Unsupported Inbox type' unless SUPPORTED_INBOX_TYPES.include?(inbox.inbox_type)
  end

  # TO-DO we clean up with better validations when campaigns evolve into more inboxes
  def ensure_correct_campaign_attributes
    return if inbox.blank?

    if ONE_OFF_INBOX_TYPES.include?(inbox.inbox_type)
      self.campaign_type = 'one_off'
      self.scheduled_at ||= Time.now.utc
    else
      self.campaign_type = 'ongoing'
      self.scheduled_at = nil
    end
  end

  def validate_url
    return unless trigger_rules['url']

    use_http_protocol = trigger_rules['url'].starts_with?('http://') || trigger_rules['url'].starts_with?('https://')
    errors.add(:url, 'invalid') if inbox.inbox_type == 'Website' && !use_http_protocol
  end

  def inbox_must_belong_to_account
    return unless inbox

    return if inbox.account_id == account_id

    errors.add(:inbox_id, 'must belong to the same account as the campaign')
  end

  def sender_must_belong_to_account
    return unless sender

    return if account.users.exists?(id: sender.id)

    errors.add(:sender_id, 'must belong to the same account as the campaign')
  end

  def captain_assistant_must_belong_to_account
    return unless captain_assistant

    return if captain_assistant.account_id == account_id

    errors.add(:captain_assistant_id, 'must belong to the same account as the campaign')
  end

  def captain_assistant_must_be_connected_to_inbox
    return unless agent?
    return if captain_assistant.blank? || inbox.blank?
    return if captain_assistant.inboxes.exists?(id: inbox_id)

    errors.add(:captain_assistant_id, 'must be configured for the campaign inbox')
  end

  def validate_ai_authoring_availability
    return unless agent?

    unless defined?(Campaigns::CaptainGeneratedMessageService)
      errors.add(:text_mode, 'AI-authored campaigns are not available')
      return
    end

    return if captain_assistant.present?

    errors.add(:inbox_id, 'must have a configured AI assistant')
  end

  def validate_official_whatsapp_delivery_policy
    return if status_only_change?
    return unless one_off?
    return if account.blank?
    return unless inbox&.channel.is_a?(Channel::Whatsapp)

    if campaign_channel_template?
      validate_channel_template_params
      return
    end

    preview = Campaigns::PreviewService.new(
      account: account,
      inbox: inbox,
      audience: audience,
      audience_import: campaign_audience_import,
      message: message,
      instructions: instructions,
      text_mode: text_mode,
      template_params: template_params,
      scheduled_at: scheduled_at
    ).call
    return unless preview.dig(:totals, 'requires_template').to_i.positive?

    errors.add(:base, Outbound::DeliveryPolicy::WHATSAPP_TEMPLATE_REQUIRED_REASON)
  end

  def audience_import_matches_campaign
    return if campaign_audience_import.blank?
    return if campaign_audience_import.account_id == account_id && campaign_audience_import.inbox_id == inbox_id

    errors.add(:campaign_audience_import_id, 'must belong to the campaign account and inbox')
  end

  def campaign_channel_template?
    template_params.present?
  end

  def validate_channel_template_params
    Campaigns::TemplateParamsValidator.validate!(inbox: inbox, template_params: template_params)
  rescue ArgumentError => e
    errors.add(:template_params, e.message)
  end

  def assign_captain_assistant_from_inbox
    return unless agent?
    return if captain_assistant.present?
    return unless inbox.respond_to?(:captain_assistant)

    self.captain_assistant = inbox.captain_assistant
  end

  def prevent_terminal_campaign_from_update
    return if campaign_status_changed?
    return unless completed? || running? || failed? || cancelled?

    errors.add :status, 'The campaign can no longer be updated'
  end

  def status_only_change?
    persisted? && changed == ['campaign_status']
  end

  # creating db triggers
  trigger.before(:insert).for_each(:row) do
    "NEW.display_id := nextval('camp_dpid_seq_' || NEW.account_id);"
  end
end
