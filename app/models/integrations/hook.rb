# == Schema Information
#
# Table name: integrations_hooks
#
#  id           :bigint           not null, primary key
#  access_token :string
#  hook_type    :integer          default("account")
#  settings     :jsonb
#  status       :integer          default("enabled")
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :integer
#  app_id       :string
#  inbox_id     :integer
#  reference_id :string
#
class Integrations::Hook < ApplicationRecord
  include Reauthorizable

  attr_readonly :app_id, :account_id, :inbox_id, :hook_type
  before_validation :ensure_hook_type
  before_validation :ensure_reference_id
  after_create :trigger_setup_if_crm
  after_commit :sync_medelement_schedule, on: [:create, :update], if: :medelement?
  after_destroy_commit :destroy_medelement_schedule, if: :medelement?
  after_destroy_commit :enqueue_medelement_cleanup, if: :medelement?

  # TODO: Remove guard once encryption keys become mandatory (target 3-4 releases out).
  encrypts :access_token, deterministic: true if Chatwoot.encryption_configured?

  validates :account_id, presence: true
  validates :app_id, presence: true
  validates :inbox_id, presence: true, if: -> { hook_type == 'inbox' }
  validate :validate_settings_json_schema
  validate :ensure_feature_enabled
  validate :ensure_required_access_token
  validate :ensure_required_secret_settings
  validates :app_id, uniqueness: { scope: [:account_id], unless: -> { app.present? && app.params[:allow_multiple_hooks].present? } }
  validates :reference_id, uniqueness: { scope: [:app_id] }, if: :macrocrm?

  # TODO: This seems to be only used for slack at the moment
  # We can add a validator when storing the integration settings and toggle this in future
  enum status: { disabled: 0, enabled: 1 }

  belongs_to :account
  belongs_to :inbox, optional: true
  has_secure_token :access_token

  enum hook_type: { account: 0, inbox: 1 }

  scope :account_hooks, -> { where(hook_type: 'account') }
  scope :inbox_hooks, -> { where(hook_type: 'inbox') }

  def app
    @app ||= Integrations::App.find(id: app_id)
  end

  def slack?
    app_id == 'slack'
  end

  def dialogflow?
    app_id == 'dialogflow'
  end

  def notion?
    app_id == 'notion'
  end

  def medelement?
    app_id == 'medelement'
  end

  def macrocrm?
    app_id == 'macrocrm'
  end

  def kaspi_pay?
    app_id == 'kaspi_pay'
  end

  def macrocrm_manager_changed_webhook_url
    frontend_url = ENV.fetch('FRONTEND_URL', nil)
    return if frontend_url.blank? || reference_id.blank? || !macrocrm?

    "#{frontend_url}/webhooks/macrocrm/#{reference_id}/manager_changed"
  end

  def secret_settings
    return {} if access_token.blank?
    return {} unless access_token.to_s.start_with?('{')

    JSON.parse(access_token)
  rescue JSON::ParserError
    {}
  end

  def kaspi_pay_metadata
    secret_settings.slice('organization_id', 'org_name', 'phone_number', 'profile_id')
  end

  def disable
    update(status: 'disabled')
  end

  def process_event(event_name)
    return process_medelement_event(event_name) if medelement?

    # OpenAI integration migrated to Captain::EditorService
    # Other integrations (slack, dialogflow, etc.) handled via HookJob
    { error: 'No processor found' }
  end

  def feature_allowed?
    return true if app.blank?

    flag = app.params[:feature_flag]
    return true unless flag

    account.feature_enabled?(flag)
  end

  private

  def ensure_feature_enabled
    errors.add(:feature_flag, 'Feature not enabled') unless feature_allowed?
  end

  def ensure_hook_type
    self.hook_type = app.params[:hook_type] if app.present?
  end

  def ensure_required_access_token
    return unless app.present? && app.params[:access_token_required]

    if kaspi_pay?
      return if disabled?

      ensure_kaspi_pay_access_token
      return
    end

    return if access_token.present?

    errors.add(:access_token, "can't be blank")
  end

  def ensure_required_secret_settings
    return unless medelement?
    return if access_token.blank?

    missing_keys = %w[company_login password].reject { |key| secret_settings[key].present? }
    missing_keys.unshift('integrator_key') if Integrations::Medelement::Configuration.new(hook: self).integrator_key.blank?
    return if missing_keys.blank?

    errors.add(:access_token, "is missing required Medelement credentials: #{missing_keys.join(', ')}")
  end

  def ensure_kaspi_pay_access_token
    missing_keys = %w[token_sn vtoken_secret profile_id].reject { |key| secret_settings[key].present? }
    return if missing_keys.blank?

    errors.add(:access_token, "is missing required Kaspi Pay credentials: #{missing_keys.join(', ')}")
  end

  def ensure_reference_id
    return unless macrocrm?
    return if reference_id.present?

    self.reference_id = SecureRandom.hex(16)
  end

  def validate_settings_json_schema
    return if app.blank? || app.params[:settings_json_schema].blank?

    errors.add(:settings, ': Invalid settings data') unless JSONSchemer.schema(app.params[:settings_json_schema]).valid?(settings)
  end

  def trigger_setup_if_crm
    # we need setup services to create data prerequisite to functioning of the integration
    # in case of Leadsquared, we need to create a custom activity type for capturing conversations and transcripts
    # https://apidocs.leadsquared.com/create-new-activity-type-api/
    return unless crm_integration?

    ::Crm::SetupJob.perform_later(id)
  end

  def crm_integration?
    %w[leadsquared].include?(app_id)
  end

  def process_medelement_event(event_name)
    return { error: 'No processor found' } unless event_name == 'sync'
    return { error: 'Medelement integration is disabled' } unless enabled?
    return { error: 'Scheduling feature is not enabled for this account' } unless feature_allowed?

    Integrations::Medelement::SyncJob.perform_later(id)
    { message: 'Medelement sync started' }
  end

  def enqueue_medelement_cleanup
    Integrations::Medelement::CleanupJob.perform_later(account_id)
  end

  def sync_medelement_schedule
    Integrations::Medelement::CronScheduleService.new(hook: self).sync!
  end

  def destroy_medelement_schedule
    Integrations::Medelement::CronScheduleService.new(hook: self).destroy!
  end
end
