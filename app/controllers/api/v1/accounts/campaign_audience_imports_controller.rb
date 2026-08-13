class Api::V1::Accounts::CampaignAudienceImportsController < Api::V1::Accounts::BaseController
  before_action :check_authorization

  def show
    audience_import = Current.account.campaign_audience_imports.find(params[:id])
    render json: serialized_import(audience_import)
  end

  def create
    inbox = Current.account.inboxes.find(params[:inbox_id])
    validate_upload!(inbox)
    audience_import = create_audience_import(inbox)
    unless attach_import_file!(audience_import)
      render json: { error: 'processing_unavailable' }, status: :service_unavailable
      return
    end
    unless enqueue_import!(audience_import)
      render json: { error: 'processing_unavailable' }, status: :service_unavailable
      return
    end

    render json: serialized_import(audience_import), status: :accepted
  rescue Campaigns::AudienceImportService::Error => e
    render json: { error: e.code }, status: :unprocessable_content
  end

  private

  def check_authorization
    authorize(Campaign, :create?)
  end

  def validate_upload!(inbox)
    file = params[:file]
    validate_file!(file)
    validate_inbox!(inbox)
    validate_storage!(file)
    return if params[:default_country].to_s.upcase.match?(Campaigns::AudienceImportService::DEFAULT_COUNTRY_PATTERN)

    raise Campaigns::AudienceImportService::Error, 'invalid_default_country'
  end

  def validate_file!(file)
    raise Campaigns::AudienceImportService::Error, 'file_required' if file.blank?
    raise Campaigns::AudienceImportService::Error, 'file_too_large' if file.size.to_i > Campaigns::AudienceImportService::MAX_FILE_SIZE
    return if File.extname(file.original_filename.to_s).casecmp?('.csv')

    raise Campaigns::AudienceImportService::Error, 'invalid_file_type'
  end

  def validate_inbox!(inbox)
    return if Campaigns::AudienceImportService::PHONE_CHANNEL_TYPES.include?(inbox.channel_type)

    raise Campaigns::AudienceImportService::Error, 'unsupported_inbox'
  end

  def validate_storage!(file)
    return if AccountLimits::StorageUsageService.new(account: Current.account).within_limit?(extra_bytes: file.size.to_i)

    raise Campaigns::AudienceImportService::Error, 'storage_limit_exceeded'
  end

  def create_audience_import(inbox)
    Current.account.campaign_audience_imports.create!(
      inbox: inbox,
      created_by: Current.user,
      token: SecureRandom.urlsafe_base64(32),
      source_filename: File.basename(params[:file].original_filename.to_s).presence || 'recipients.csv',
      default_country: params[:default_country].to_s.upcase,
      expires_at: CampaignAudienceImport::TOKEN_TTL.from_now
    )
  end

  def enqueue_import!(audience_import)
    Campaigns::ProcessAudienceImportJob.perform_later(audience_import)
    true
  rescue StandardError => e
    Rails.logger.error("[CAMPAIGN AUDIENCE IMPORT] import=#{audience_import.id} enqueue failed: #{e.class}")
    transitioned = transition_pending_to_failed(audience_import)
    Campaigns::ProcessAudienceImportJob.enqueue_source_purge(audience_import)
    !transitioned
  end

  def attach_import_file!(audience_import)
    audience_import.import_file.attach(params[:file])
    true
  rescue StandardError => e
    Rails.logger.error("[CAMPAIGN AUDIENCE IMPORT] import=#{audience_import.id} upload failed: #{e.class}")
    transition_pending_to_failed(audience_import)
    Campaigns::ProcessAudienceImportJob.enqueue_source_purge(audience_import)
    false
  end

  def transition_pending_to_failed(audience_import)
    audience_import.with_lock do
      audience_import.reload
      next false unless audience_import.pending?

      audience_import.update!(status: :failed, processing_error: 'processing_failed')
      true
    end
  end

  def serialized_import(audience_import)
    {
      id: audience_import.id,
      token: audience_import.token,
      status: audience_import.status,
      processing_error: audience_import.processing_error,
      source_filename: audience_import.source_filename,
      total_rows: audience_import.total_rows,
      recipient_count: audience_import.recipient_count,
      created_count: audience_import.created_count,
      existing_count: audience_import.existing_count,
      duplicate_count: audience_import.duplicate_count,
      invalid_count: audience_import.invalid_count,
      conflict_count: audience_import.conflict_count,
      error_samples: audience_import.error_samples,
      expires_at: audience_import.expires_at.iso8601
    }
  end
end
