# == Schema Information
#
# Table name: accounts
#
#  id                      :integer          not null, primary key
#  auto_resolve_duration   :integer
#  custom_attributes       :jsonb
#  domain                  :string(100)
#  feature_flags           :bigint           default(0), not null
#  feature_flags_overflow  :jsonb            not null
#  internal_attributes     :jsonb            not null
#  limits                  :jsonb
#  locale                  :integer          default("en")
#  name                    :string           not null
#  settings                :jsonb
#  status                  :integer          default("active")
#  support_email           :string(100)
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  billing_organization_id :bigint
#
# Indexes
#
#  index_accounts_on_billing_organization_id  (billing_organization_id)
#  index_accounts_on_status                   (status)
#
# Foreign Keys
#
#  fk_rails_...  (billing_organization_id => billing_organizations.id)
#

class Account < ApplicationRecord
  include Rails.application.routes.url_helpers
  include AccountStorageLimitable
  # used for single column multi flags
  include FlagShihTzu
  include Reportable
  include Featurable
  include CacheKeys
  include CaptainFeaturable
  include AccountEmailRateLimitable
  include AccountWorkspaceWorkingHours

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

  store_accessor :settings, :audio_transcriptions, :auto_resolve_label
  store_accessor :settings, :captain_models, :captain_features, :captain_runtime
  store_accessor :settings, :captain_observability, :mcp_access
  store_accessor :settings, :reporting_timezone
  store_accessor :settings, :keep_pending_on_bot_failure
  store_accessor :settings, :captain_auto_resolve_mode
  store_accessor :settings,
                 :scheduling_contact_required,
                 :scheduling_company_enabled,
                 :default_appointment_touch_plan_id,
                 :default_deal_touch_plan_id,
                 :default_task_touch_plan_id
  include AccountCaptainAutoResolve

  belongs_to :billing_organization, optional: true

  has_many :account_users, dependent: :destroy_async

  has_many :api_channels, dependent: :destroy_async, class_name: '::Channel::Api'
  has_many :articles, dependent: :destroy_async, class_name: '::Article'
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
  has_many :crm_field_definitions, dependent: :destroy_async, class_name: '::Crm::FieldDefinition'
  has_many :crm_deals, dependent: :destroy_async, class_name: '::Crm::Deal'
  has_many :crm_deal_contacts, dependent: :destroy_async, class_name: '::Crm::DealContact'
  has_many :crm_tasks, dependent: :destroy_async, class_name: '::Crm::Task'
  has_many :crm_events, dependent: :destroy_async, class_name: '::Crm::Event'
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
  has_many :kaspi_pay_payments, dependent: :destroy_async, class_name: 'KaspiPay::Payment'
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

  def default_touch_plan_id_for(entity_kind)
    case entity_kind.to_s
    when 'appointment'
      default_appointment_touch_plan_id
    when 'deal'
      default_deal_touch_plan_id
    when 'task'
      default_task_touch_plan_id
    end
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

  private

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
