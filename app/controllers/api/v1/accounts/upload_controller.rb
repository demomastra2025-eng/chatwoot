class Api::V1::Accounts::UploadController < Api::V1::Accounts::BaseController
  def create
    result = if params[:attachment].present?
               create_from_file
             elsif params[:external_url].present?
               create_from_url
             else
               render_error(I18n.t('errors.upload.missing_input'), :unprocessable_content)
             end

    render_success(result) if result.is_a?(ActiveStorage::Blob)
  rescue Whatsapp::TemplateMediaValidator::InvalidMediaError => e
    render_error(e.message, :unprocessable_content)
  end

  private

  def create_from_file
    attachment = params[:attachment]
    unless storage_limit_available?(attachment.size)
      return render_error(AccountLimits::StorageUsageService::LIMIT_EXCEEDED_MESSAGE,
                          :payment_required)
    end

    content_type = validate_whatsapp_template_media!(
      io: attachment.tempfile,
      file_name: attachment.original_filename,
      byte_size: attachment.size
    ) || attachment.content_type
    create_and_save_blob(attachment.tempfile, attachment.original_filename, content_type)
  end

  def validate_whatsapp_template_media!(io:, file_name:, byte_size:)
    return unless whatsapp_template_media_upload?

    Whatsapp::TemplateMediaValidator.validate!(
      io: io,
      file_name: file_name,
      media_type: params[:media_type],
      byte_size: byte_size
    )
  end

  def create_from_url
    SafeFetch.fetch(params[:external_url].to_s, **remote_fetch_options) do |result|
      create_from_remote_file(result)
    end
  rescue Whatsapp::TemplateMediaValidator::InvalidMediaError
    raise
  rescue SafeFetch::Error => e
    render_safe_fetch_error(e)
  rescue StandardError
    render_error(I18n.t('errors.upload.unexpected'), :internal_server_error)
  end

  def create_from_remote_file(result)
    unless storage_limit_available?(result.tempfile.size)
      return render_error(AccountLimits::StorageUsageService::LIMIT_EXCEEDED_MESSAGE, :payment_required)
    end

    content_type = validate_whatsapp_template_media!(
      io: result.tempfile,
      file_name: result.filename,
      byte_size: result.tempfile.size
    ) || result.content_type
    create_and_save_blob(result.tempfile, result.filename, content_type)
  end

  def render_safe_fetch_error(error)
    message = case error
              when SafeFetch::HttpError
                I18n.t('errors.upload.fetch_failed_with_message', message: error.message)
              when SafeFetch::FetchError
                I18n.t('errors.upload.fetch_failed')
              when SafeFetch::FileTooLargeError
                I18n.t('errors.upload.file_too_large')
              when SafeFetch::UnsupportedContentTypeError
                I18n.t('errors.upload.unsupported_content_type')
              else
                I18n.t('errors.upload.invalid_url')
              end
    render_error(message, :unprocessable_content)
  end

  def remote_fetch_options
    return {} unless whatsapp_template_media_upload?

    {
      max_bytes: Whatsapp::TemplateMediaValidator::MAX_FILE_SIZE,
      validate_content_type: false
    }
  end

  def create_and_save_blob(io, filename, content_type)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: io,
      filename: filename,
      content_type: content_type,
      metadata: upload_metadata
    )
    Whatsapp::TemplateAssetUploadService.schedule_cleanup(blob) if whatsapp_template_media_upload?
    blob
  end

  def render_success(file_blob)
    blob_id = if whatsapp_template_media_upload?
                Whatsapp::TemplateAssetUploadService.signed_blob_id(file_blob, account_id: Current.account.id)
              else
                file_blob.signed_id
              end
    render json: { file_url: url_for(file_blob), blob_id: blob_id }
  end

  def render_error(message, status)
    render json: { error: message }, status: status
  end

  def storage_limit_available?(extra_bytes)
    AccountLimits::StorageUsageService.new(account: Current.account).within_limit?(extra_bytes: extra_bytes)
  end

  def upload_metadata
    return { 'account_id' => Current.account.id } unless whatsapp_template_media_upload?

    Whatsapp::TemplateAssetUploadService.blob_metadata(account_id: Current.account.id)
  end

  def whatsapp_template_media_upload?
    params[:upload_purpose] == Whatsapp::TemplateAssetUploadService::UPLOAD_PURPOSE
  end
end
