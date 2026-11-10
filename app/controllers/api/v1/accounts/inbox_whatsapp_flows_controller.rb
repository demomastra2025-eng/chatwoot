# frozen_string_literal: true

class Api::V1::Accounts::InboxWhatsappFlowsController < Api::V1::Accounts::BaseController
  PROVISION_BOOKING_FIELDS = %i[name locale publish specialist_label service_label confirm_cta clinic_preset flow_type].freeze
  CREATE_FLOW_FIELDS = [:name, :flow_json, :use_endpoint, :publish, :kind, { categories: [] }].freeze

  before_action :fetch_inbox
  before_action :validate_whatsapp_cloud_channel

  def index
    render json: {
      whatsapp_flows: management_service.public_flows_config
    }, status: :ok
  end

  def setup_encryption
    result = management_service.setup_encryption!(
      rotate_keys: ActiveModel::Type::Boolean.new.cast(params[:rotate_keys])
    )
    return render_failure(result) unless result[:success]

    @inbox.reload
    render 'api/v1/accounts/inboxes/show', status: :ok
  end

  def sync
    result = management_service.sync_flows!
    return render_failure(result) unless result[:success]

    @inbox.reload
    render 'api/v1/accounts/inboxes/show', status: :ok
  end

  def provision_booking
    result = management_service.provision_booking_flow!(provision_booking_params.to_h)
    return render_failure(result) unless result[:success]

    @inbox.reload
    render 'api/v1/accounts/inboxes/show', status: :created
  end

  def create
    result = management_service.create_flow!(create_flow_params.to_h)
    return render_failure(result) unless result[:success]

    @inbox.reload
    render 'api/v1/accounts/inboxes/show', status: :created
  rescue ActionController::ParameterMissing
    render json: { error: 'Flow parameters are required' }, status: :unprocessable_content
  end

  def publish
    result = management_service.publish_flow!(params[:id])
    return render_failure(result) unless result[:success]

    @inbox.reload
    render 'api/v1/accounts/inboxes/show', status: :ok
  end

  def destroy
    result = management_service.remove_flow!(params[:id])
    return render_failure(result) unless result[:success]

    @inbox.reload
    render 'api/v1/accounts/inboxes/show', status: :ok
  end

  private

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize @inbox, :whatsapp_flows?
  end

  def validate_whatsapp_cloud_channel
    return if @inbox.whatsapp? && @inbox.channel.provider == 'whatsapp_cloud'

    render json: { error: 'WhatsApp Flows are only available for WhatsApp Cloud channels' }, status: :bad_request
  end

  def management_service
    @management_service ||= Whatsapp::Flows::ManagementService.new(whatsapp_channel: @inbox.channel)
  end

  def provision_booking_params
    params.fetch(:whatsapp_flow, params).permit(*PROVISION_BOOKING_FIELDS)
  end

  def create_flow_params
    params.require(:whatsapp_flow).permit(*CREATE_FLOW_FIELDS)
  end

  def render_failure(result)
    safe_result = Meta::CredentialDataSanitizer.sanitize(
      result.slice(:error, :details),
      secrets: Meta::CredentialDataSanitizer.channel_secrets(@inbox.channel)
    )
    render json: {
      error: safe_result[:error],
      details: safe_result[:details]
    }.compact, status: :unprocessable_content
  end
end
