class Api::V1::Accounts::InboxWhatsappTemplatesController < Api::V1::Accounts::BaseController
  before_action :fetch_inbox
  before_action :validate_whatsapp_cloud_channel
  before_action :prevent_csat_template_deletion!, only: [:destroy]

  def create
    result = template_management_service.create_template(template_params.to_h)
    return render_failure(result) unless result[:success]

    @inbox.reload
    render 'api/v1/accounts/inboxes/show', status: :created
  rescue ActionController::ParameterMissing
    render json: { error: 'Template parameters are required' }, status: :unprocessable_content
  end

  def destroy
    result = template_management_service.delete_template(params[:template_name])
    return render_failure(result) unless result[:success]

    @inbox.reload
    render 'api/v1/accounts/inboxes/show', status: :ok
  end

  private

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize @inbox, :whatsapp_templates?
  end

  def validate_whatsapp_cloud_channel
    return if @inbox.whatsapp? && @inbox.channel.provider == 'whatsapp_cloud'

    render json: { error: 'WhatsApp template management is only available for WhatsApp Cloud channels' }, status: :bad_request
  end

  def prevent_csat_template_deletion!
    return unless params[:template_name] == @inbox.csat_config&.dig('template', 'name')

    render json: { error: 'CSAT-managed templates cannot be deleted from the template library' }, status: :unprocessable_content
  end

  def render_failure(result)
    render json: {
      error: result[:error],
      details: result[:details]
    }, status: :unprocessable_content
  end

  def template_management_service
    @template_management_service ||= Whatsapp::TemplateManagementService.new(whatsapp_channel: @inbox.channel)
  end

  def template_params
    params.require(:template).permit(
      :name,
      :language,
      :category,
      :header_type,
      :header_text,
      :body_text,
      :footer_text,
      :sample_media_url,
      body_examples: {},
      header_examples: {},
      buttons: %i[type text url example phone_number]
    )
  end
end
