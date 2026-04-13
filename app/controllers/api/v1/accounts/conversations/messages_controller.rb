class Api::V1::Accounts::Conversations::MessagesController < Api::V1::Accounts::Conversations::BaseController
  def index
    @messages = message_finder.perform
  end

  def create
    user = Current.user || @resource
    mb = Messages::MessageBuilder.new(user, @conversation, params)
    @message = mb.perform
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def update
    if content_update_requested?
      update_message_content
    elsif status_update_requested?
      ensure_api_inbox!
      return if performed?

      Messages::StatusUpdateService.new(message, permitted_params[:status], permitted_params[:external_error]).perform
      @message = message
    else
      render json: { error: 'No supported message update params were provided' }, status: :unprocessable_content
    end
  end

  def destroy
    @message = Messages::DeleteService.new(message: message).perform
  rescue Messages::DeleteService::Error => e
    render_could_not_create_error(e.message)
  end

  def retry
    return if message.blank?

    service = Messages::StatusUpdateService.new(message, 'sent')
    service.perform
    message.update!(content_attributes: {})
    ::SendReplyJob.perform_later(message.id)
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def translate
    return head :ok if already_translated_content_available?

    translated_content = Integrations::GoogleTranslate::ProcessorService.new(
      message: message,
      target_language: permitted_params[:target_language]
    ).perform

    if translated_content.present?
      translations = {}
      translations[permitted_params[:target_language]] = translated_content
      translations = message.translations.merge!(translations) if message.translations.present?
      message.update!(translations: translations)
    end

    render json: { content: translated_content }
  end

  private

  def message
    @message ||= @conversation.messages.find(permitted_params[:id])
  end

  def message_finder
    @message_finder ||= MessageFinder.new(@conversation, params)
  end

  def permitted_params
    params.permit(:id, :target_language, :status, :external_error, :content)
  end

  def already_translated_content_available?
    message.translations.present? && message.translations[permitted_params[:target_language]].present?
  end

  def content_update_requested?
    params.key?(:content)
  end

  def status_update_requested?
    permitted_params[:status].present? || permitted_params[:external_error].present?
  end

  def update_message_content
    @message = Messages::UpdateContentService.new(
      message: message,
      content: permitted_params[:content]
    ).perform
  rescue Messages::UpdateContentService::Error => e
    render_could_not_create_error(e.message)
  end

  def ensure_api_inbox!
    return if @conversation.inbox.api?

    render json: { error: 'Message status update is only allowed for API inboxes' }, status: :forbidden
  end
end
