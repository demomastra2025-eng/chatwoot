# == Schema Information
#
# Table name: accounts
#
#  id                     :integer          not null, primary key
#  auto_resolve_duration  :integer
#  custom_attributes      :jsonb
#  domain                 :string(100)
#  feature_flags          :bigint           default(0), not null
#  feature_flags_overflow :jsonb            not null
#  internal_attributes    :jsonb            not null
#  limits                 :jsonb
#  locale                 :integer          default("en")
#  name                   :string           not null
#  settings               :jsonb
#  status                 :integer          default("active")
#  support_email          :string(100)
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#
# Indexes
#
#  index_accounts_on_status  (status)
#

# rubocop:disable Metrics/ClassLength
class Account < ApplicationRecord
  TRIAL_FEATURES = %w[
    channel_website channel_whatsapp channel_voice voice_recorder
    captain_integration agent_bots crm help_center macros canned_responses
    inbox_management team_management custom_attributes automations
  ].freeze
  TRIAL_SNAPSHOT_KEY = 'trial_snapshot'.freeze
  TRIAL_LOCKED_LIMITS = %w[agents inboxes].freeze

  include Rails.application.routes.url_helpers
  include AccountStorageLimitable
  # used for single column multi flags
  include FlagShihTzu
  include Reportable
  include Featurable
  include CacheKeys
  include CaptainFeaturable
  include AccountEmailRateLimitable

  include AccountSettingsSchema

  DEFAULT_QUERY_SETTING = {
    flag_query_mode: :bit_operator,
    check_for_column: false
  }.freeze

  validates :name, presence: true
  validates :domain, length: { maximum: 100 }
  validates_with JsonSchemaValidator,
                 schema: SETTINGS_PARAMS_SCHEMA,
                 attribute_resolver: ->(record) { record.settings }
  validate :validate_reporting_timezone
  validate :validate_support_email_format, if: :will_save_change_to_support_email?

  store_accessor :settings, :auto_resolve_after, :auto_resolve_message, :auto_resolve_ignore_waiting

  store_accessor :settings, :audio_transcriptions, :call_transcriptions, :auto_resolve_label
  store_accessor :settings, :captain_models, :captain_features, :captain_runtime
  store_accessor :settings, :captain_observability, :mcp_access
  store_accessor :settings, :reporting_timezone
  store_accessor :settings, :keep_pending_on_bot_failure
  store_accessor :settings, :captain_auto_resolve_mode
  store_accessor :settings, :conversation_status_reason_config
  store_accessor :settings, :scheduling_contact_required, :scheduling_company_enabled
  store_accessor :settings, :conversation_assignment_policy_id
  include AccountCaptainAutoResolve

  has_many :account_users, dependent: :destroy_async
  has_many :agent_bot_inboxes, dependent: :destroy_async
  has_many :agent_bots, dependent: :destroy_async
  has_many :api_channels, dependent: :destroy_async, class_name: '::Channel::Api'
  has_many :articles, dependent: :destroy_async, class_name: '::Article'
  has_many :attachments, dependent: :destroy_async
  has_many :assignment_policies, dependent: :destroy_async
  has_many :automation_rules, dependent: :destroy_async
  has_many :bulk_action_runs, dependent: :destroy_async
  has_many :macros, dependent: :destroy_async
  has_many :campaigns, dependent: :destroy_async
  has_many :campaign_audience_imports, dependent: :destroy_async
  has_many :campaign_deliveries, dependent: :delete_all
  has_many :confirmation_requests, dependent: :destroy_async
  has_many :reminders, dependent: :destroy_async
  has_many :reminder_groups, dependent: :destroy_async
  has_many :touch_plan_enrollments, dependent: :destroy_async
  has_many :touch_occurrence_claims, dependent: :destroy_async
  has_many :canned_responses, dependent: :destroy_async
  has_many :categories, dependent: :destroy_async, class_name: '::Category'
  has_many :contacts, dependent: :destroy_async
  has_many :conversations, dependent: :destroy_async
  has_many :conversation_status_transitions, dependent: :destroy_async
  has_many :crm_pipelines, dependent: :destroy_async, class_name: '::Crm::Pipeline'
  has_many :crm_stages, dependent: :destroy_async, class_name: '::Crm::Stage'
  has_many :crm_task_statuses, dependent: :destroy_async, class_name: '::Crm::TaskStatus'
  has_many :crm_task_types, dependent: :destroy_async, class_name: '::Crm::TaskType'
  has_many :crm_task_outcomes, dependent: :destroy_async, class_name: '::Crm::TaskOutcome'
  has_many :crm_field_definitions, dependent: :destroy_async, class_name: '::Crm::FieldDefinition'
  has_many :crm_deals, dependent: :destroy_async, class_name: '::Crm::Deal'
  has_many :crm_deal_contacts, dependent: :destroy_async, class_name: '::Crm::DealContact'
  has_many :crm_tasks, dependent: :destroy_async, class_name: '::Crm::Task'
  has_many :crm_events, dependent: :destroy_async, class_name: '::Crm::Event'
  has_many :crm_stage_visits, dependent: :delete_all, class_name: '::Crm::StageVisit'
  has_many :crm_stage_field_requirements, dependent: :delete_all, class_name: '::Crm::StageFieldRequirement'
  has_many :crm_comments, dependent: :destroy_async, class_name: '::Crm::Comment'
  has_many :csat_survey_responses, dependent: :destroy_async
  has_many :custom_attribute_definitions, dependent: :destroy_async
  has_many :custom_filters, dependent: :destroy_async
  has_many :dashboard_apps, dependent: :destroy_async
  has_many :data_imports, dependent: :destroy_async
  has_many :email_channels, dependent: :destroy_async, class_name: '::Channel::Email'
  has_many :facebook_pages, dependent: :destroy_async, class_name: '::Channel::FacebookPage'
  has_many :instagram_channels, dependent: :destroy_async, class_name: '::Channel::Instagram'
  has_many :tiktok_channels, dependent: :destroy_async, class_name: '::Channel::Tiktok'
  has_many :hooks, dependent: :destroy_async, class_name: 'Integrations::Hook'
  has_many :inboxes, dependent: :destroy_async
  has_many :lead_forms, dependent: :destroy_async
  has_many :lead_submissions, dependent: :destroy_async
  has_many :labels, dependent: :destroy_async
  has_many :line_channels, dependent: :destroy_async, class_name: '::Channel::Line'

  has_many :llm_events, dependent: :destroy_async
  has_many :llm_event_annotations, dependent: :destroy_async
  has_many :mentions, dependent: :destroy_async
  has_many :messages, dependent: :destroy_async
  has_many :meta_ad_referrals, dependent: :delete_all
  has_many :notes, dependent: :destroy_async
  has_many :notification_settings, dependent: :destroy_async
  has_many :notifications, dependent: :destroy_async
  has_many :portals, dependent: :destroy_async, class_name: '::Portal'
  has_many :scheduling_appointments, dependent: :destroy_async, class_name: 'Scheduling::Appointment'
  has_many :scheduling_break_rules, dependent: :destroy_async, class_name: 'Scheduling::BreakRule'
  has_many :scheduling_expenses, dependent: :destroy_async, class_name: 'Scheduling::Expense'
  has_many :scheduling_holidays, dependent: :destroy_async, class_name: 'Scheduling::Holiday'
  has_many :scheduling_payments, dependent: :destroy_async, class_name: 'Scheduling::Payment'

  has_many :scheduling_resources, dependent: :destroy_async, class_name: 'Scheduling::Resource'
  has_many :scheduling_service_prices, dependent: :destroy_async, class_name: 'Scheduling::ServicePrice'
  has_many :scheduling_services, dependent: :destroy_async, class_name: 'Scheduling::Service'
  has_many :scheduling_time_offs, dependent: :destroy_async, class_name: 'Scheduling::TimeOff'
  has_many :scheduling_work_rules, dependent: :destroy_async, class_name: 'Scheduling::WorkRule'
  has_many :scheduling_workday_overrides, dependent: :destroy_async, class_name: 'Scheduling::WorkdayOverride'
  has_many :sms_channels, dependent: :destroy_async, class_name: '::Channel::Sms'
  has_many :teams, dependent: :destroy_async
  has_many :telegram_channels, dependent: :destroy_async, class_name: '::Channel::Telegram'
  has_many :telegram_personal_channels, dependent: :destroy_async, class_name: '::Channel::TelegramPersonal'
  has_many :twilio_sms, dependent: :destroy_async, class_name: '::Channel::TwilioSms'
  has_many :twitter_profiles, dependent: :destroy_async, class_name: '::Channel::TwitterProfile'
  has_many :users, through: :account_users
  has_many :vk_community_channels, dependent: :destroy_async, class_name: '::Channel::VkCommunity'
  has_many :web_widgets, dependent: :destroy_async, class_name: '::Channel::WebWidget'
  has_many :webhooks, dependent: :destroy_async
  has_many :whatsapp_channels, dependent: :destroy_async, class_name: '::Channel::Whatsapp'
  has_many :whatsapp_web_channels, dependent: :destroy_async, class_name: '::Channel::WhatsappWeb'
  has_many :working_hours, dependent: :destroy_async

  has_one_attached :contacts_export
  has_one_attached :logo
  account_storage_attachments :logo

  enum :locale, LANGUAGES_CONFIG.map { |key, val| [val[:iso_639_1_code], key] }.to_h, prefix: true
  enum :status, { active: 0, suspended: 1 }

  scope :with_auto_resolve, -> { where("(settings ->> 'auto_resolve_after')::int IS NOT NULL") }

  before_validation :validate_limit_keys
  before_validation :normalize_default_settings
  after_create_commit :notify_creation
  after_destroy :remove_account_sequences

  def agents
    users.where(account_users: { role: :agent })
  end

  def administrators
    users.where(account_users: { role: :administrator })
  end

  def all_conversation_tags
    # returns array of tags
    conversation_ids = conversations.pluck(:id)
    ActsAsTaggableOn::Tagging.includes(:tag)
                             .where(context: 'labels',
                                    taggable_type: 'Conversation',
                                    taggable_id: conversation_ids)
                             .map { |tagging| tagging.tag.name }
  end

  def webhook_data
    {
      id: id,
      name: name
    }
  end

  def inbound_email_domain
    domain.presence || GlobalConfig.get('MAILER_INBOUND_EMAIL_DOMAIN')['MAILER_INBOUND_EMAIL_DOMAIN'] || ENV.fetch('MAILER_INBOUND_EMAIL_DOMAIN',
                                                                                                                   false)
  end

  def support_email
    super.presence || ENV.fetch('MAILER_SENDER_EMAIL') { GlobalConfig.get('MAILER_SUPPORT_EMAIL')['MAILER_SUPPORT_EMAIL'] }
  end

  def logo_url
    return unless logo.attached?

    url_for(logo)
  end

  def scheduling_contact_required?
    return true unless settings.is_a?(Hash)

    value = settings['scheduling_contact_required']
    value.nil? || ActiveModel::Type::Boolean.new.cast(value)
  end

  def scheduling_company_enabled?
    return true unless settings.is_a?(Hash)

    value = settings['scheduling_company_enabled']
    value.nil? || ActiveModel::Type::Boolean.new.cast(value)
  end

  def audio_transcriptions_enabled?
    ActiveModel::Type::Boolean.new.cast(settings.to_h['audio_transcriptions'])
  end

  def call_transcriptions_enabled?
    value = settings.to_h['call_transcriptions']
    value = settings.to_h['audio_transcriptions'] if value.nil?
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def workspace_assignment_policy_selected?
    conversation_assignment_policy_id.present?
  end

  def workspace_assignment_policy
    return unless workspace_assignment_policy_selected?

    assignment_policies.find_by(id: conversation_assignment_policy_id, enabled: true)
  end

  def workspace_assignment_policy_available?
    !workspace_assignment_policy_selected? || workspace_assignment_policy.present?
  end

  def usage_limits
    {
      agents: ChatwootApp.max_limit.to_i,
      inboxes: ChatwootApp.max_limit.to_i
    }
  end

  def locale_english_name
    # the locale can also be something like pt_BR, en_US, fr_FR, etc.
    # the format is `<locale_code>_<country_code>`
    # we need to extract the language code from the locale
    account_locale = locale&.split('_')&.first
    ISO_639.find(account_locale)&.english_name&.downcase || 'english'
  end

  def trial?
    custom_attributes&.dig('plan_type') == 'trial'
  end

  def trial_expires_at
    Time.zone.parse(custom_attributes['trial_expires_at'].to_s) if custom_attributes&.dig('trial_expires_at').present?
  rescue ArgumentError
    nil
  end

  def trial_active?
    trial? && trial_expires_at.present? && trial_expires_at > Time.current
  end

  def trial_expired?
    trial? && (trial_expires_at.blank? || trial_expires_at <= Time.current)
  end

  def trial_snapshot?
    snapshot = custom_attributes&.[](TRIAL_SNAPSHOT_KEY)
    snapshot.is_a?(Hash) && snapshot['features'].is_a?(Array)
  end

  def extend_trial!(days = 3)
    with_lock do
      reload
      raise ArgumentError, 'Only a snapshot-backed trial can be extended' unless trial? && trial_snapshot?

      attrs = (custom_attributes || {}).deep_dup
      now = Time.current
      current_expiry = trial_expires_at
      base_time = current_expiry && current_expiry > now ? current_expiry : now
      reopening = attrs.delete('trial_expired_at').present?
      attrs['plan_type'] = 'trial'
      attrs['trial_expires_at'] = (base_time + days.days).iso8601
      self.custom_attributes = attrs
      reopen_trial! if reopening
      save!
    end
  end

  # Starts a full-feature trial. The snapshot, feature activation and expiry write happen under one row lock.
  def activate_trial!(days = 3)
    with_lock do
      reload
      current_plan = custom_attributes.to_h['plan_type']
      raise ArgumentError, 'A paid or manually assigned plan cannot be replaced by a trial' if current_plan.present? && current_plan != 'trial'

      snapshot_pre_trial_state!
      enable_features(*TRIAL_FEATURES)
      attrs = (custom_attributes || {}).deep_dup
      attrs['plan_type'] = 'trial'
      attrs['trial_expires_at'] = (Time.current + days.days).iso8601
      attrs.delete('trial_expired_at')
      self.custom_attributes = attrs
      save!
    end
  end

  # Ends only a snapshot-backed trial. Scheduled expiry rechecks expiry under this lock; an explicit
  # superadmin action may end an active trial early, but cannot mutate a manually assigned plan.
  def expire_trial!(only_if_expired: false)
    with_lock do
      reload
      attrs = (custom_attributes || {}).deep_dup
      snapshot = attrs[TRIAL_SNAPSHOT_KEY]
      return false unless eligible_for_trial_expiry?(attrs, snapshot, only_if_expired)

      attrs['trial_expires_at'] = 1.minute.ago.iso8601
      attrs['trial_expired_at'] = Time.current.iso8601
      self.custom_attributes = attrs
      disable_features(*(TRIAL_FEATURES - snapshot['features']))
      self.limits = (limits || {}).merge(TRIAL_LOCKED_LIMITS.index_with { 0 })
      save!
      true
    end
  end

  # Upload/quota reads use the last background measurement. A cold HTTP read must never traverse recording directories.
  def local_recordings_bytes
    overview = Accounts::StorageOverviewService.new(account: self)
    overview.schedule_refresh
    measured = overview.snapshot&.dig(:recording_total_bytes)
    measured.nil? ? Redis::Alfred.get(local_recordings_last_good_cache_key).to_i : measured.to_i
  end

  def local_recordings_bytes_cache_key
    "account:#{id}:local_recordings_bytes"
  end

  def local_recordings_last_good_cache_key
    "account:#{id}:local_recordings_bytes_last_good"
  end

  def storage_breakdown(force_refresh: false, heavy_recordings: nil, recording_usage: nil)
    unless force_refresh || recording_usage
      cached = Accounts::StorageOverviewService.new(account: self).schedule_refresh
      return cached[:breakdown] if cached

      return %i[recordings audio images videos documents captain other trash total last_updated_at]
             .index_with { nil }.merge(calculating: true, by_inbox: [])
    end

    calculate_storage_breakdown(heavy_recordings: heavy_recordings, recording_usage: recording_usage)
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
  def calculate_storage_breakdown(heavy_recordings: nil, recording_usage: nil)
    recording_usage ||= Storage::RecordingInventory.new(account: self).calculate
    recording_usage[:primary_rows].each { |session, bytes| heavy_recordings&.add(session: session, byte_size: bytes) }
    usage_by_type = owned_attachment_usage_rows.each_with_object(Hash.new(0)) do |(_blob_id, size, file_type), totals|
      type = Attachment.file_types.key(file_type)
      totals[type] += size.to_i if type
    end
    audio_bytes = usage_by_type['audio'].to_i
    image_bytes = usage_by_type['image'].to_i
    video_bytes = usage_by_type['video'].to_i
    doc_bytes = usage_by_type['file'].to_i

    active_attachment_blob_ids = active_attachment_scope.where("(attachments.meta->'trash') IS NULL")
                                                        .select('active_storage_attachments.blob_id').distinct
    trash_attachment_blob_ids = active_attachment_scope.where("(attachments.meta->'trash') IS NOT NULL")
                                                       .select('active_storage_attachments.blob_id').distinct
    captain_source_blob_ids = if defined?(Captain::Document) && Captain::Document.table_exists?
                                ActiveStorage::Attachment.where(record_type: 'Captain::Document', name: %w[pdf_file source_file])
                                                         .where(record_id: Captain::Document.where(account_id: id).select(:id))
                                                         .select(:blob_id).distinct
                              else
                                ActiveStorage::Blob.none.select(:id)
                              end
    captain_blob_ids = captain_source_blob_ids
    if defined?(ActiveStorage::VariantRecord) && ActiveStorage::VariantRecord.table_exists?
      captain_variant_blob_ids = ActiveStorage::Attachment.where(
        record_type: ActiveStorage::VariantRecord.name,
        name: 'image',
        record_id: ActiveStorage::VariantRecord.where(blob_id: captain_source_blob_ids).select(:id)
      ).select(:blob_id).distinct
      captain_blob_ids = ActiveStorage::Blob.where(id: captain_source_blob_ids)
                                            .or(ActiveStorage::Blob.where(id: captain_variant_blob_ids))
                                            .select(:id)
    end
    captain_bytes = ActiveStorage::Blob.where(id: captain_blob_ids).where.not(id: active_attachment_blob_ids).sum(:byte_size).to_i
    trash_att_bytes = ActiveStorage::Blob.where(id: trash_attachment_blob_ids)
                                         .where.not(id: active_attachment_blob_ids)
                                         .where.not(id: captain_blob_ids)
                                         .sum(:byte_size).to_i

    storage_service = AccountLimits::StorageUsageService.new(account: self)
    rec_bytes = recording_usage[:total]
    active_recordings_bytes = recording_usage[:active]
    trashed_recordings_bytes = recording_usage[:trash]
    active_bytes = storage_service.active_storage_bytes
    total_bytes = active_bytes + rec_bytes

    trash_bytes = trashed_recordings_bytes + trash_att_bytes
    active_storage_known = audio_bytes + image_bytes + video_bytes + doc_bytes + captain_bytes + trash_att_bytes
    other_bytes = [active_bytes - active_storage_known, 0].max

    {
      recordings: active_recordings_bytes,
      audio: audio_bytes,
      images: image_bytes,
      videos: video_bytes,
      documents: doc_bytes,
      captain: captain_bytes,
      other: other_bytes,
      trash: trash_bytes,
      total: total_bytes,
      by_inbox: calculate_inbox_storage_breakdown(recording_usage: recording_usage, total_bytes: total_bytes),
      recordings_reconciled_at: Time.zone.at(recording_usage[:reconciled_at]).iso8601,
      last_updated_at: Time.current.iso8601
    }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength

  def owned_attachment_usage_rows
    scope = active_attachment_scope.where("(attachments.meta->'trash') IS NULL")
                                   .select(
                                     'DISTINCT ON (active_storage_blobs.id) active_storage_blobs.id, ' \
                                     'active_storage_blobs.byte_size, attachments.file_type'
                                   )
                                   .order('active_storage_blobs.id, attachments.file_type')

    ActiveRecord::Base.connection.select_rows(scope.to_sql)
  end

  def active_attachment_scope
    ActiveStorage::Attachment.joins(:blob)
                             .joins(
                               'INNER JOIN attachments ON attachments.id = active_storage_attachments.record_id ' \
                               "AND active_storage_attachments.record_type = 'Attachment'"
                             )
                             .where(attachments: { account_id: id })
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
  def calculate_inbox_storage_breakdown(recording_usage: nil, total_bytes: nil)
    inbox_scope = active_attachment_scope.joins('INNER JOIN messages ON messages.id = attachments.message_id')
                                         .select(
                                           'DISTINCT ON (active_storage_blobs.id) active_storage_blobs.id, ' \
                                           'active_storage_blobs.byte_size, messages.inbox_id, attachments.id'
                                         )
                                         .where(messages: { account_id: id })
                                         .order('active_storage_blobs.id, messages.inbox_id NULLS LAST, attachments.id')
    inbox_rows = ActiveRecord::Base.connection.select_rows(inbox_scope.to_sql)
    inbox_usage = Hash.new { |usage, inbox_id| usage[inbox_id] = { bytes: 0, count: 0 } }
    inbox_rows.each do |_blob_id, bytes, inbox_id|
      inbox_usage[inbox_id][:bytes] += bytes.to_i
      inbox_usage[inbox_id][:count] += 1
    end

    recording_usage ||= Storage::RecordingInventory.new(account: self).calculate
    recordings_by_inbox = recording_usage[:by_inbox]

    rows = inboxes.select(:id, :name, :channel_type).map do |inbox|
      attachments = inbox_usage[inbox.id] || { bytes: 0, count: 0 }
      recordings = recordings_by_inbox[inbox.id] || { bytes: 0, count: 0 }
      {
        id: inbox.id,
        name: inbox.name,
        channel_type: inbox.channel_type,
        bytes: attachments[:bytes] + recordings[:bytes],
        files_count: attachments[:count] + recordings[:count]
      }
    end

    # Captain files, unattached blobs and unlinked local recordings still belong to the shared physical
    # quota. Keep them in a clearly named bucket so the inbox totals add up to the account total.
    known_bytes = rows.sum { |row| row[:bytes] }
    usage = AccountLimits::StorageUsageService.new(account: self)
    # Same physical total as the breakdown: it does not depend on whether recordings count towards the quota.
    total_bytes ||= usage.active_storage_bytes + recording_usage[:total]
    unassigned_bytes = [total_bytes - known_bytes, 0].max
    if unassigned_bytes.positive?
      rows << {
        id: nil,
        name: I18n.t('storage_management.no_channel'),
        channel_type: nil,
        bytes: unassigned_bytes,
        files_count: 0
      }
    end
    rows
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength

  private

  # Remembers the enabled features and the agent/inbox limits from before the trial. The first snapshot wins,
  # so repeated activations or expirations never overwrite what the account originally had.
  # The first snapshot must win; the only nested branch upgrades a legacy limits-only snapshot on explicit opt-in.
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def snapshot_pre_trial_state!(limits_only: false)
    attrs = (custom_attributes || {}).dup
    snapshot = attrs[TRIAL_SNAPSHOT_KEY].is_a?(Hash) ? attrs[TRIAL_SNAPSHOT_KEY].deep_dup : nil
    if snapshot
      complete_explicit_trial_snapshot!(attrs, snapshot) unless limits_only || snapshot['features'].is_a?(Array)
      return
    end

    snapshot = { 'limits' => (limits || {}).slice(*TRIAL_LOCKED_LIMITS), 'taken_at' => Time.current.iso8601 }
    snapshot['features'] = selected_feature_flags.map(&:to_s) unless limits_only
    self.custom_attributes = attrs.merge(TRIAL_SNAPSHOT_KEY => snapshot)
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def eligible_for_trial_expiry?(attrs, snapshot, only_if_expired)
    trial? && snapshot.is_a?(Hash) && snapshot['features'].is_a?(Array) &&
      attrs['trial_expired_at'].blank? &&
      (!only_if_expired || trial_expires_at.blank? || trial_expires_at <= Time.current)
  end

  def complete_explicit_trial_snapshot!(attrs, snapshot)
    # Preserve the first feature snapshot; a legacy limits-only snapshot gains features only on explicit opt-in.
    snapshot['features'] = selected_feature_flags.map(&:to_s)
    snapshot['taken_at'] ||= Time.current.iso8601
    snapshot['limits'] ||= (limits || {}).slice(*TRIAL_LOCKED_LIMITS)
    self.custom_attributes = attrs.merge(TRIAL_SNAPSHOT_KEY => snapshot)
  end

  # An expired trial that gets extended gets its trial features and its previous limits back.
  def reopen_trial!
    snapshot = custom_attributes[TRIAL_SNAPSHOT_KEY] || {}
    enable_features(*TRIAL_FEATURES) if snapshot.key?('features')
    self.limits = (limits || {}).except(*TRIAL_LOCKED_LIMITS).merge(snapshot['limits'] || {})
  end

  def storage_limit_account
    self
  end

  def notify_creation
    Rails.configuration.dispatcher.dispatch(ACCOUNT_CREATED, Time.zone.now, account: self)
  end

  trigger.after(:insert).for_each(:row) do
    "execute format('create sequence IF NOT EXISTS conv_dpid_seq_%s', NEW.id);"
  end

  trigger.name('camp_dpid_before_insert').after(:insert).for_each(:row) do
    "execute format('create sequence IF NOT EXISTS camp_dpid_seq_%s', NEW.id);"
  end

  def validate_limit_keys
    # method overridden in enterprise module
  end

  def normalize_default_settings
    self.settings = (settings || {}).dup
    settings['audio_transcriptions'] = false if settings['audio_transcriptions'].nil?
  end

  def validate_reporting_timezone
    return if reporting_timezone.blank? || ActiveSupport::TimeZone[reporting_timezone].present?

    errors.add(:reporting_timezone, I18n.t('errors.account.reporting_timezone.invalid'))
  end

  def validate_support_email_format
    value = attributes['support_email']
    return if value.blank?

    parsed = Mail::Address.new(value).address
    errors.add(:support_email, I18n.t('errors.account.support_email.invalid')) if parsed.blank?
  rescue Mail::Field::ParseError, Mail::Field::IncompleteParseError
    errors.add(:support_email, I18n.t('errors.account.support_email.invalid'))
  end

  def remove_account_sequences
    ActiveRecord::Base.connection.exec_query("drop sequence IF EXISTS camp_dpid_seq_#{id}")
    ActiveRecord::Base.connection.exec_query("drop sequence IF EXISTS conv_dpid_seq_#{id}")
  end
end

Account.prepend_mod_with('Account')
Account.prepend_mod_with('Account::PlanUsageAndLimits')
Account.include_mod_with('Concerns::Account')
Account.include_mod_with('Audit::Account')

# rubocop:enable Metrics/ClassLength
