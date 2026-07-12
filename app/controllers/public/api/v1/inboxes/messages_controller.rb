class Public::Api::V1::Inboxes::MessagesController < Public::Api::V1::InboxesController
  before_action :set_message, only: [:update]

  def index
    @messages = @conversation.nil? ? [] : message_finder.perform
  end

  def create
    @message = message_by_source_id
    return handle_existing_source_id if @message

    @message = @conversation.messages.new(message_params)
    return render_payment_required(AccountLimits::StorageUsageService::LIMIT_EXCEEDED_MESSAGE) unless storage_limit_available?

    build_attachment
    @message.save!
  rescue ActiveRecord::RecordNotUnique
    @message = message_by_source_id
    return handle_existing_source_id if @message

    raise
  end

  def update
    render json: { error: 'You cannot update the CSAT survey after 14 days' }, status: :unprocessable_content and return if check_csat_locked

    @message.update!(message_update_params)
  rescue StandardError => e
    render json: { error: @contact.errors, message: e.message }.to_json, status: :internal_server_error
  end

  private

  def build_attachment
    return if params[:attachments].blank?

    params[:attachments].each do |uploaded_attachment|
      @message.attachments.new(
        account_id: @message.account_id,
        file_type: helpers.file_type(uploaded_attachment&.content_type),
        file: uploaded_attachment
      )
    end
  end

  def storage_limit_available?
    return true if params[:attachments].blank?

    extra_bytes = params[:attachments].sum { |uploaded_attachment| uploaded_attachment.size.to_i }
    AccountLimits::StorageUsageService.new(account: @message.account).within_limit?(extra_bytes: extra_bytes)
  end

  def message_finder_params
    {
      filter_internal_messages: true,
      before: params[:before]
    }
  end

  def message_finder
    @message_finder ||= MessageFinder.new(@conversation, message_finder_params)
  end

  def message_update_params
    params.permit(submitted_values: [:name, :title, :value, { csat_survey_response: [:feedback_message, :rating] }])
  end

  def permitted_params
    params.permit(:content, :echo_id, :source_id)
  end

  def set_message
    @message = @conversation.messages.find(params[:id])
  end

  def message_params
    {
      account_id: @conversation.account_id,
      sender: @contact_inbox.contact,
      content: permitted_params[:content],
      inbox_id: @conversation.inbox_id,
      echo_id: permitted_params[:echo_id],
      source_id: permitted_params[:source_id].presence,
      message_type: :incoming
    }
  end

  def message_by_source_id
    source_id = permitted_params[:source_id].presence
    return if source_id.blank?

    @conversation.inbox.messages.find_by(source_id: source_id)
  end

  def handle_existing_source_id
    return if @message.conversation_id == @conversation.id

    render json: { error: 'source_id is already used by another conversation' }, status: :conflict
  end

  def check_csat_locked
    (Time.zone.now.to_date - @message.created_at.to_date).to_i > 14 and @message.content_type == 'input_csat'
  end
end
