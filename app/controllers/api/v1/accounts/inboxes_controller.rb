class Api::V1::Accounts::InboxesController < Api::V1::Accounts::BaseController
  include Api::V1::InboxesHelper
  before_action :fetch_inbox, except: [:index, :create]
  before_action :fetch_agent_bot, only: [:set_agent_bot]
  before_action :validate_limit, only: [:create]
  # we are already handling the authorization in fetch inbox
  before_action :check_authorization, except: [:show, :health]
  before_action :validate_whatsapp_cloud_channel, only: [:health]
  before_action :validate_whatsapp_web_channel,
                only: [:refresh_whatsapp_web_qr, :reconnect_whatsapp_web, :disconnect_whatsapp_web, :repair_whatsapp_web,
                       :whatsapp_web_diagnostics]

  def index
    scope = Current.account.inboxes.order_by_name
    includes_associations = [:channel, { avatar_attachment: [:blob] }]
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

  def destroy
    ::DeleteObjectJob.perform_later(@inbox, Current.user, request.ip) if @inbox.present?
    render status: :ok, json: { message: I18n.t('messages.inbox_deletetion_response') }
  end

  def sync_templates
    return render status: :unprocessable_content, json: { error: 'Template sync is only available for WhatsApp channels' } unless whatsapp_channel?

    trigger_template_sync
    render status: :ok, json: { message: 'Template sync initiated successfully' }
  rescue StandardError => e
    render status: :internal_server_error, json: { error: e.message }
  end

  def health
    health_data = Whatsapp::HealthService.new(@inbox.channel).fetch_health_status
    render json: health_data
  rescue StandardError => e
    Rails.logger.error "[INBOX HEALTH] Error fetching health data: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_content
  end

  def refresh_whatsapp_web_qr
    if truthy_param?(:status_only)
      @inbox.channel.sync_connection_state!
    else
      @inbox.channel.refresh_qr!
    end

    render :show
  rescue StandardError => e
    log_whatsapp_web_runtime_error('refresh_whatsapp_web_qr', e)
    render json: { error: e.message }, status: :unprocessable_content
  end

  def reconnect_whatsapp_web
    @inbox.channel.reconnect!
    render :show
  rescue StandardError => e
    log_whatsapp_web_runtime_error('reconnect_whatsapp_web', e)
    render json: { error: e.message }, status: :unprocessable_content
  end

  def disconnect_whatsapp_web
    @inbox.channel.disconnect!
    render :show
  rescue StandardError => e
    log_whatsapp_web_runtime_error('disconnect_whatsapp_web', e)
    render json: { error: e.message }, status: :unprocessable_content
  end

  def repair_whatsapp_web
    @inbox.channel.repair!
    render :show
  rescue StandardError => e
    log_whatsapp_web_runtime_error('repair_whatsapp_web', e)
    render json: { error: e.message }, status: :unprocessable_content
  end

  def whatsapp_web_diagnostics
    render json: @inbox.channel.diagnostics
  rescue StandardError => e
    log_whatsapp_web_runtime_error('whatsapp_web_diagnostics', e)
    render json: { error: e.message }, status: :unprocessable_content
  end

  private

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:id])
    authorize @inbox, :show?
  end

  def fetch_agent_bot
    @agent_bot = AgentBot.find(params[:agent_bot]) if params[:agent_bot]
  end

  def validate_whatsapp_cloud_channel
    return if @inbox.channel.is_a?(Channel::Whatsapp) && @inbox.channel.provider == 'whatsapp_cloud'

    render json: { error: 'Health data only available for WhatsApp Cloud API channels' }, status: :bad_request
  end

  def create_channel
    return unless allowed_channel_types.include?(permitted_params[:channel][:type])

    channel_type_from_params.create!(channel_create_attributes)
  end

  def allowed_channel_types
    %w[web_widget api email line telegram whatsapp whatsapp_web sms]
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
    render json: { message: e }, status: :unprocessable_content and return
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
    params.permit(*inbox_attributes, channel: [:type, *channel_attributes])
  end

  def channel_type_from_params
    {
      'web_widget' => Channel::WebWidget,
      'api' => Channel::Api,
      'email' => Channel::Email,
      'line' => Channel::Line,
      'telegram' => Channel::Telegram,
      'whatsapp' => Channel::Whatsapp,
      'whatsapp_web' => Channel::WhatsappWeb,
      'sms' => Channel::Sms
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

  def whatsapp_channel?
    @inbox.whatsapp? || (@inbox.twilio? && @inbox.channel.whatsapp?)
  end

  def trigger_template_sync
    if @inbox.whatsapp?
      Channels::Whatsapp::TemplatesSyncJob.perform_later(@inbox.channel)
    elsif @inbox.twilio? && @inbox.channel.whatsapp?
      Channels::Twilio::TemplatesSyncJob.perform_later(@inbox.channel)
    end
  end

  def validate_whatsapp_web_channel
    return if @inbox.whatsapp_web?

    render json: { error: 'This action is only available for WhatsApp Web channels' }, status: :bad_request
  end

  def truthy_param?(key)
    ActiveModel::Type::Boolean.new.cast(params[key])
  end
end

Api::V1::Accounts::InboxesController.prepend_mod_with('Api::V1::Accounts::InboxesController')
