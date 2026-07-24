class Api::V1::Accounts::InboxesController < Api::V1::Accounts::BaseController
  include Api::V1::InboxesHelper
  rescue_from Telephony::Error, with: :render_telephony_error
  rescue_from Whatsapp::WabaLock::LockAcquisitionError, with: :render_waba_lock_contention

  VOICE_TOP_LEVEL_CHANNEL_ATTRIBUTES = %i[phone_number provider provider_config].freeze

  before_action :fetch_inbox, except: [:index, :create]
  before_action :fetch_agent_bot, only: [:set_agent_bot]
  before_action :validate_limit, only: [:create]
  # we are already handling the authorization in fetch inbox
  before_action :check_authorization, except: [:show]
  before_action :render_pending_deletion_response,
                only: [:update, :avatar, :set_agent_bot, :refresh_whatsapp_web_qr, :reconnect_whatsapp_web,
                       :disconnect_whatsapp_web, :repair_whatsapp_web]
  before_action :render_pending_deletion_diagnostics,
                only: [:whatsapp_web_diagnostics]

  include Api::V1::Accounts::Concerns::WhatsappHealthManagement
  before_action :validate_whatsapp_web_channel,
                only: [:refresh_whatsapp_web_qr, :reconnect_whatsapp_web, :disconnect_whatsapp_web, :repair_whatsapp_web,
                       :whatsapp_web_diagnostics]

  def index
    scope = Current.account.inboxes.active.order_by_name
    includes_associations = [:channel, :portal, { avatar_attachment: [:blob] }]
    includes_associations << { captain_inbox: :captain_assistant } if Inbox.reflect_on_association(:captain_inbox)

    @inboxes = policy_scope(scope.includes(*includes_associations))
  end

  def show; end

  # Deprecated: This API will be removed in 2.7.0
  def assignable_agents
    @assignable_agents = @inbox.assignable_agents
  end

  def campaigns
    @campaigns = @inbox.campaigns
  end

  def avatar
    @inbox.avatar.attachment.destroy! if @inbox.avatar.attached?
    head :ok
  end

  def create
    Whatsapp::WabaLock.with_locks(whatsapp_create_waba_ids) do
      ActiveRecord::Base.transaction do
        channel = create_channel
        @inbox = Current.account.inboxes.build(
          {
            name: inbox_name(channel),
            channel: channel
          }.merge(
            permitted_params.except(:channel)
          )
        )
        @inbox.save!
        sync_voice_telephony!(channel)
      end
    end
  end

  def update
    @sync_telegram_personal_channel_after_update = false

    with_stable_whatsapp_update_locks do
      ActiveRecord::Base.transaction do
        @inbox.channel.lock! if @inbox.channel.is_a?(Channel::Whatsapp)
        inbox_params = permitted_params.except(:channel, :csat_config)
        inbox_params[:csat_config] = format_csat_config(permitted_params[:csat_config]) if permitted_params[:csat_config].present?
        @inbox.update!(inbox_params)
        update_inbox_working_hours
        update_channel if channel_update_required?
      end
    end

    sync_telegram_personal_channel_after_update!
  rescue TelegramPersonal::GatewayClient::GatewayError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  def agent_bot
    @agent_bot = @inbox.agent_bot
  end

  def set_agent_bot
    if @agent_bot
      agent_bot_inbox = @inbox.agent_bot_inbox || AgentBotInbox.new(inbox: @inbox)
      agent_bot_inbox.agent_bot = @agent_bot
      agent_bot_inbox.save!
    elsif @inbox.agent_bot_inbox.present?
      @inbox.agent_bot_inbox.destroy!
    end
    head :ok
  end

  def reset_secret
    return head :not_found unless @inbox.api?

    @inbox.channel.reset_secret!
  end

  def destroy
    if virtual_pbx_voice_inbox?
      destroy_virtual_pbx_voice_inbox
      return
    end

    if @inbox.deleting?
      render status: :accepted, json: pending_deletion_payload(@inbox)
      return
    end

    ActiveRecord::Base.transaction do
      @inbox.mark_pending_deletion!
      ::DeleteObjectJob.perform_later(@inbox, Current.user, request.ip)
    end

    render status: :accepted, json: pending_deletion_payload(@inbox)
  end

  def refresh_whatsapp_web_qr
    if truthy_param?(:status_only)
      @inbox.channel.sync_connection_state!
      recover_whatsapp_web_auth_artifact_if_needed!
      render_whatsapp_web_inbox(include_qr_code: truthy_param?(:include_qr_code) == true)
    else
      @inbox.channel.refresh_qr!(artifact_type: params[:artifact_type].presence || 'qr')
      render_whatsapp_web_inbox
    end
  rescue StandardError => e
    log_whatsapp_web_runtime_error('refresh_whatsapp_web_qr', e)
    if truthy_param?(:status_only)
      @inbox.channel.mark_failed!(e.message) if @inbox.channel.respond_to?(:mark_failed!)
      render_whatsapp_web_inbox(status: :ok) and return
    end

    render json: { error: e.message }, status: :unprocessable_content
  end

  def reconnect_whatsapp_web
    @inbox.channel.reconnect!
    render_whatsapp_web_inbox
  rescue StandardError => e
    log_whatsapp_web_runtime_error('reconnect_whatsapp_web', e)
    render json: { error: e.message }, status: :unprocessable_content
  end

  def disconnect_whatsapp_web
    @inbox.channel.disconnect!
    render_whatsapp_web_inbox
  rescue StandardError => e
    log_whatsapp_web_runtime_error('disconnect_whatsapp_web', e)
    render json: { error: e.message }, status: :unprocessable_content
  end

  def repair_whatsapp_web
    @inbox.channel.repair!
    render_whatsapp_web_inbox
  rescue StandardError => e
    log_whatsapp_web_runtime_error('repair_whatsapp_web', e)
    render json: { error: e.message }, status: :unprocessable_content
  end

  def whatsapp_web_diagnostics
    render json: @inbox.channel.diagnostics
  rescue StandardError => e
    log_whatsapp_web_runtime_error('whatsapp_web_diagnostics', e)
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:id])
    authorize @inbox, :show?
  end

  def fetch_agent_bot
    @agent_bot = AgentBot.accessible_to(Current.account).find(params[:agent_bot]) if params[:agent_bot]
  end

  def create_channel
    return unless allowed_channel_types.include?(permitted_params[:channel][:type])

    channel_type_from_params.create!(channel_create_attributes)
  end

  def whatsapp_create_waba_ids
    channel_params = (params[:channel]&.to_unsafe_h || {}).with_indifferent_access
    return [] unless channel_params[:type] == 'whatsapp' && channel_params[:provider] == 'whatsapp_cloud'

    [channel_params.dig(:provider_config, :business_account_id)]
  end

  def whatsapp_update_waba_ids
    return [] unless @inbox.channel.is_a?(Channel::Whatsapp)

    channel_params = (params[:channel]&.to_unsafe_h || {}).with_indifferent_access
    target_provider = channel_params[:provider].presence || @inbox.channel.provider
    return [] unless @inbox.channel.provider == 'whatsapp_cloud' || target_provider == 'whatsapp_cloud'

    [
      @inbox.channel.provider_config.to_h['business_account_id'],
      channel_params.dig(:provider_config, :business_account_id)
    ]
  end

  def with_stable_whatsapp_update_locks
    loop do
      locked_waba_ids = normalized_waba_ids(whatsapp_update_waba_ids)
      stable_identity = false
      result = Whatsapp::WabaLock.with_locks(locked_waba_ids) do
        @inbox.channel.reload if @inbox.channel.is_a?(Channel::Whatsapp)
        next unless (normalized_waba_ids(whatsapp_update_waba_ids) - locked_waba_ids).empty?

        stable_identity = true
        yield
      end
      return result if stable_identity
    end
  end

  def normalized_waba_ids(waba_ids)
    Array(waba_ids).compact_blank.map(&:to_s).uniq
  end

  def allowed_channel_types
    types = %w[web_widget api email line telegram telegram_personal linkedin_personal weixin whatsapp whatsapp_web sms vk_community]
    types << 'voice' if defined?(Channel::Voice)
    types
  end

  def update_inbox_working_hours
    @inbox.update_working_hours(params.permit(working_hours: Inbox::OFFISABLE_ATTRS)[:working_hours]) if params[:working_hours]
  end

  def update_channel
    channel_attributes = get_channel_attributes(@inbox.channel_type)
    return if permitted_params(channel_attributes)[:channel].blank?

    validate_and_update_email_channel(channel_attributes) if @inbox.inbox_type == 'Email'

    reauthorize_and_update_channel(channel_attributes)
    update_channel_feature_flags
  end

  def channel_update_required?
    permitted_params(get_channel_attributes(@inbox.channel_type))[:channel].present?
  end

  def validate_and_update_email_channel(channel_attributes)
    validate_email_channel(channel_attributes)
  rescue StandardError => e
    render json: { message: e }, status: :unprocessable_entity and return
  end

  def reauthorize_and_update_channel(channel_attributes)
    identity_guard = Whatsapp::ChannelIdentityUpdateGuard.new(@inbox.channel)
    identity_guard.validate!(permitted_params(channel_attributes)[:channel])
    channel_params = identity_guard.validate!(normalized_channel_update_params(channel_attributes))
    @inbox.channel.reauthorized! if @inbox.channel.respond_to?(:reauthorized!)
    @inbox.channel.update!(channel_params)
    @sync_telegram_personal_channel_after_update ||= telegram_personal_runtime_state_update?(channel_params)
    sync_voice_telephony!(@inbox.channel)
  end

  def telegram_personal_runtime_state_update?(channel_params)
    @inbox.channel.is_a?(Channel::TelegramPersonal) &&
      (channel_params.key?(:runtime_state) || channel_params.key?('runtime_state'))
  end

  def sync_telegram_personal_channel_after_update!
    return unless @sync_telegram_personal_channel_after_update

    TelegramPersonal::GatewayClient.new(channel: @inbox.channel).sync_channel!
  end

  def update_channel_feature_flags
    return unless @inbox.web_widget?
    return unless permitted_params(Channel::WebWidget::EDITABLE_ATTRS)[:channel].key? :selected_feature_flags

    @inbox.channel.selected_feature_flags = permitted_params(Channel::WebWidget::EDITABLE_ATTRS)[:channel][:selected_feature_flags]
    @inbox.channel.save!
  end

  def sync_voice_telephony!(channel)
    return unless defined?(Channel::Voice) && channel.is_a?(Channel::Voice)

    sync_voice_captain_inbox!(channel)
    return unless channel.provider.in?(Channel::Voice::PROVIDER_OWNED_SIP_PROVIDERS)

    Telephony::NumberBinding.sync_from_voice_channel!(channel.reload)
  end

  def sync_voice_captain_inbox!(channel)
    return unless Object.const_defined?('CaptainInbox')
    return unless Current.account.respond_to?(:captain_assistants)

    assistant_id = voice_captain_assistant_id(channel)
    voice_inbox = channel.inbox || @inbox
    return if assistant_id.blank? || voice_inbox.blank?

    assistant = Current.account.captain_assistants.find(assistant_id)
    captain_inbox = ::CaptainInbox.find_or_initialize_by(inbox: voice_inbox)
    captain_inbox.captain_assistant = assistant
    captain_inbox.save! if captain_inbox.changed? || captain_inbox.new_record?
  end

  def voice_captain_assistant_id(channel)
    channel.provider_config_hash.with_indifferent_access[:captain_assistant_id].presence
  rescue JSON::ParserError, TypeError
    nil
  end

  def format_csat_config(config)
    formatted = {
      'display_type' => config['display_type'] || 'emoji',
      'message' => config['message'] || '',
      :survey_rules => {
        'operator' => config.dig('survey_rules', 'operator') || 'contains',
        'values' => config.dig('survey_rules', 'values') || []
      },
      'button_text' => config['button_text'] || 'Please rate us',
      'language' => config['language'] || 'ru'
    }
    format_template_config(config, formatted)
    formatted
  end

  def format_template_config(config, formatted)
    formatted['template'] = config['template'] if config['template'].present?
  end

  def log_whatsapp_web_runtime_error(action, error)
    Rails.logger.error(
      "[WHATSAPP WEB] #{action} failed for inbox=#{@inbox&.id} channel=#{@inbox&.channel&.id}: #{error.class}: #{error.message}"
    )
  end

  def render_whatsapp_web_inbox(include_qr_code: true, status: :ok)
    @inbox.reload
    render :show, status: status, locals: { include_whatsapp_web_qr_code: include_qr_code }
  end

  def virtual_pbx_voice_inbox?
    return false unless @inbox.channel_type == 'Channel::Voice'
    return false unless @inbox.respond_to?(:telephony_number_binding)

    @inbox.telephony_number_binding.present?
  end

  def destroy_virtual_pbx_voice_inbox
    inbox_id = @inbox.id
    payload = Telephony::VirtualPbx::ProvisioningService.new(
      account: Current.account,
      current_user: Current.user
    ).delete_channel(
      inbox_id: inbox_id,
      confirm: true,
      dry_run: false,
      remote_commit: managed_virtual_pbx_remote_commit?,
      include_diagnostics: false
    )

    unless payload[:deleted]
      render json: { code: 'TELEPHONY_DELETE_FAILED', error: 'Managed voice inbox deletion failed', payload: payload },
             status: :unprocessable_content
      return
    end

    render status: :accepted, json: managed_virtual_pbx_deletion_payload(inbox_id, payload)
  end

  def managed_virtual_pbx_remote_commit?
    ActiveModel::Type::Boolean.new.cast(params.fetch(:remote_commit, false))
  end

  def managed_virtual_pbx_deletion_payload(inbox_id, payload)
    {
      message: I18n.t('messages.inbox_deletetion_response'),
      id: inbox_id,
      deleting: false,
      deleted: true,
      deleted_inbox_id: payload[:deleted_inbox_id],
      remote_commit: payload[:remote_commit],
      payload: payload
    }.compact
  end

  def pending_deletion_payload(inbox)
    inbox.reload
    channel = inbox.channel
    {
      message: I18n.t('messages.inbox_deletetion_response'),
      id: inbox.id,
      deleting: inbox.deleting?,
      deleting_at: inbox.deleting_at&.iso8601,
      channel_type: inbox.display_channel_type,
      lifecycle_state: channel.try(:lifecycle_state),
      connection_state: channel.try(:connection_state)
    }.compact
  end

  def render_telephony_error(error)
    body = { code: error.code, error: error.message }
    body[:details] = error.details if error.details.present?
    render json: body, status: error.status
  end

  def render_waba_lock_contention(_error)
    render json: { error: 'Another WhatsApp Business Account operation is already in progress' }, status: :conflict
  end

  def inbox_attributes
    [:name, :avatar, :greeting_enabled, :greeting_message, :enable_email_collect, :csat_survey_enabled,
     :enable_auto_assignment, :working_hours_enabled, :out_of_office_message, :timezone, :allow_messages_after_resolved,
     :lock_to_single_conversation, :portal_id, :sender_name_type, :business_name,
     { csat_config: [:display_type, :message, :button_text, :language,
                     { survey_rules: [:operator, { values: [] }],
                       template: [:name, :template_id, :friendly_name, :content_sid, :approval_sid, :created_at, :language, :status] }] }]
  end

  def permitted_params(channel_attributes = [])
    # We will remove this line after fixing https://linear.app/chatwoot/issue/CW-1567/null-value-passed-as-null-string-to-backend
    params.each { |k, v| params[k] = params[k] == 'null' ? nil : v }
    normalize_voice_channel_params!
    params.permit(*inbox_attributes, channel: [:type, *channel_attributes])
  end

  def normalize_voice_channel_params!
    channel = params[:channel]
    return unless channel.respond_to?(:[])
    return unless channel[:type].to_s == 'voice'

    VOICE_TOP_LEVEL_CHANNEL_ATTRIBUTES.each do |attribute|
      value = params[attribute]
      next if value.nil?
      next if channel.key?(attribute) || channel.key?(attribute.to_s)

      channel[attribute] = value
      params.delete(attribute)
      params.delete(attribute.to_s)
    end
  end

  def channel_type_from_params
    {
      'web_widget' => Channel::WebWidget,
      'api' => Channel::Api,
      'email' => Channel::Email,
      'line' => Channel::Line,
      'telegram' => Channel::Telegram,
      'telegram_personal' => Channel::TelegramPersonal,
      'linkedin_personal' => Channel::LinkedinPersonal,
      'weixin' => Channel::Weixin,
      'whatsapp' => Channel::Whatsapp,
      'whatsapp_web' => Channel::WhatsappWeb,
      'sms' => Channel::Sms,
      'vk_community' => Channel::VkCommunity,
      'voice' => (Channel::Voice if defined?(Channel::Voice))
    }[permitted_params[:channel][:type]]
  end

  def channel_create_attributes
    attrs = permitted_params(channel_type_from_params::EDITABLE_ATTRS)[:channel].except(:type).merge(account: Current.account)
    attrs = enriched_whatsapp_cloud_channel_attributes(attrs) if channel_type_from_params == Channel::Whatsapp
    return attrs unless channel_type_from_params == Channel::WhatsappWeb

    attrs[:provider_config] = whatsapp_web_provider_config(attrs[:provider_config])
    attrs
  end

  def normalized_channel_update_params(channel_attributes)
    channel_params = permitted_params(channel_attributes)[:channel]
    return normalized_telegram_personal_channel_params(channel_params) if @inbox.channel.is_a?(Channel::TelegramPersonal)
    return normalized_voice_channel_params(channel_params) if defined?(Channel::Voice) && @inbox.channel.is_a?(Channel::Voice)
    return channel_params unless @inbox.channel.is_a?(Channel::Whatsapp)

    enriched_whatsapp_cloud_channel_attributes(channel_params, existing_channel: @inbox.channel)
  end

  def normalized_telegram_personal_channel_params(channel_params)
    attrs = channel_params.to_h.with_indifferent_access
    return attrs unless attrs.key?(:runtime_state)

    attrs[:runtime_state] = @inbox.channel.runtime_state_payload.merge(attrs[:runtime_state].to_h)
    attrs
  end

  def normalized_voice_channel_params(channel_params)
    attrs = channel_params.to_h.with_indifferent_access
    return attrs if attrs[:provider_config].blank?

    provider_config = @inbox.channel.provider_config.to_h.deep_stringify_keys
    attrs[:provider_config] = provider_config.deep_merge(attrs[:provider_config].to_h.deep_stringify_keys)
    attrs
  end

  def enriched_whatsapp_cloud_channel_attributes(channel_params, existing_channel: nil)
    attrs = channel_params.to_h.with_indifferent_access
    provider = attrs[:provider].presence || existing_channel&.provider
    return attrs unless provider == 'whatsapp_cloud'
    return attrs if attrs[:provider_config].blank?

    provider_config = existing_channel&.provider_config.to_h || {}
    provider_config = provider_config.merge(attrs[:provider_config].to_h.deep_stringify_keys)
    token_health = inspect_whatsapp_cloud_token(provider_config)
    provider_config[Channel::Whatsapp::TOKEN_HEALTH_CONFIG_KEY] = token_health if token_health.present?
    attrs[:provider_config] = provider_config
    attrs
  end

  def inspect_whatsapp_cloud_token(provider_config)
    return nil if provider_config['api_key'].blank? || provider_config['business_account_id'].blank?

    Whatsapp::TokenValidationService.new(
      provider_config['api_key'],
      provider_config['business_account_id'],
      phone_number_id: provider_config['phone_number_id']
    ).perform
  end

  def whatsapp_web_provider_config(existing_config)
    config = (existing_config || {}).deep_stringify_keys
    config['client'] ||= 'onelink'
    config['service_user'] ||= {
      'id' => Current.user&.id,
      'email' => Current.user&.email,
      'name' => Current.user&.name
    }.compact
    config
  end

  def get_channel_attributes(channel_type)
    channel_type.constantize.const_defined?(:EDITABLE_ATTRS) ? channel_type.constantize::EDITABLE_ATTRS.presence : []
  end

  def validate_whatsapp_web_channel
    return if @inbox.whatsapp_web?

    render json: { error: 'This action is only available for WhatsApp Web channels' }, status: :bad_request
  end

  def render_pending_deletion_response
    return unless @inbox.deleting?

    render :show, status: :accepted
  end

  def render_pending_deletion_diagnostics
    return unless @inbox.deleting?

    render json: { deleting: true }, status: :accepted
  end

  def recover_whatsapp_web_auth_artifact_if_needed!
    return unless truthy_param?(:include_qr_code)

    channel = @inbox.channel
    return unless channel.respond_to?(:auth_artifact_valid?) && channel.respond_to?(:refresh_qr!)
    return if channel.qr_code.present? || channel.auth_artifact_valid?
    return if channel.lifecycle_state == 'qr_scanned' && channel.auth_artifact_scanned_recent?
    return if channel.lifecycle_state.in?(%w[connected failed deleting])
    return if channel.connection_state.in?(%w[open refused reconnecting])

    channel.refresh_qr!(artifact_type: params[:artifact_type].presence || channel.auth_artifact_type || 'qr')
  end

  def truthy_param?(key)
    ActiveModel::Type::Boolean.new.cast(params[key])
  end
end

Api::V1::Accounts::InboxesController.prepend_mod_with('Api::V1::Accounts::InboxesController')
