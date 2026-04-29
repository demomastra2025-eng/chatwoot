class Api::V1::Accounts::InboxesController < Api::V1::Accounts::BaseController
  include Api::V1::InboxesHelper
  rescue_from Telephony::Error, with: :render_telephony_error

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

  def update
    ActiveRecord::Base.transaction do
      inbox_params = permitted_params.except(:channel, :csat_config)
      inbox_params[:csat_config] = format_csat_config(permitted_params[:csat_config]) if permitted_params[:csat_config].present?
      @inbox.update!(inbox_params)
      update_inbox_working_hours
      update_channel if channel_update_required?
    end
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
    @agent_bot = AgentBot.find(params[:agent_bot]) if params[:agent_bot]
  end

  def create_channel
    return unless allowed_channel_types.include?(permitted_params[:channel][:type])

    channel_type_from_params.create!(channel_create_attributes)
  end

  def allowed_channel_types
    %w[web_widget api email line telegram telegram_personal weixin whatsapp whatsapp_web sms vk_community]
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
    @inbox.channel.reauthorized! if @inbox.channel.respond_to?(:reauthorized!)
    @inbox.channel.update!(permitted_params(channel_attributes)[:channel])
    sync_voice_telephony!(@inbox.channel)
  end

  def update_channel_feature_flags
    return unless @inbox.web_widget?
    return unless permitted_params(Channel::WebWidget::EDITABLE_ATTRS)[:channel].key? :selected_feature_flags

    @inbox.channel.selected_feature_flags = permitted_params(Channel::WebWidget::EDITABLE_ATTRS)[:channel][:selected_feature_flags]
    @inbox.channel.save!
  end

  def sync_voice_telephony!(channel)
    return unless defined?(Channel::Voice) && channel.is_a?(Channel::Voice)
    return unless channel.provider == 'fonoster'

    binding = Telephony::NumberBinding.sync_from_voice_channel!(channel.reload)
    return if binding.blank?

    Telephony::RoutingService.new(account: Current.account).update_number_route!(
      number_binding: binding,
      attributes: binding.routing_policy.attributes.symbolize_keys.slice(
        :mode, :ai_app_ref, :operator_agent_ref, :operator_agent_aor, :fallback_mode, :fallback_message
      )
    )
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
      'weixin' => Channel::Weixin,
      'whatsapp' => Channel::Whatsapp,
      'whatsapp_web' => Channel::WhatsappWeb,
      'sms' => Channel::Sms,
      'vk_community' => Channel::VkCommunity
    }[permitted_params[:channel][:type]]
  end

  def channel_create_attributes
    attrs = permitted_params(channel_type_from_params::EDITABLE_ATTRS)[:channel].except(:type).merge(account: Current.account)
    return attrs unless channel_type_from_params == Channel::WhatsappWeb

    attrs[:provider_config] = whatsapp_web_provider_config(attrs[:provider_config])
    attrs
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

  def truthy_param?(key)
    ActiveModel::Type::Boolean.new.cast(params[key])
  end
end

Api::V1::Accounts::InboxesController.prepend_mod_with('Api::V1::Accounts::InboxesController')
