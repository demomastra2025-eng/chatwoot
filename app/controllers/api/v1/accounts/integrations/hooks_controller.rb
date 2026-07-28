class Api::V1::Accounts::Integrations::HooksController < Api::V1::Accounts::BaseController
  MEDELEMENT_CATALOG_MAX_BYTES = 5.megabytes
  MEDELEMENT_CATALOG_LOCK_TIMEOUT = 10.minutes

  before_action :fetch_hook, except: [:create]
  before_action :check_authorization
  before_action :ensure_medelement_hook!, only: [:run_sync, :import_catalog]

  def create
    @hook = Current.account.hooks.create!(normalized_params)
  end

  def update
    @hook.update!(normalized_params.slice(:status, :settings, :access_token))
  end

  def process_event
    response = @hook.process_event(params[:event])

    # for cases like an invalid event, or when conversation does not have enough messages
    # for a label suggestion, the response is nil
    if response.nil?
      render json: { message: nil }
    elsif response[:error]
      render json: { error: response[:error] }, status: :unprocessable_content
    else
      render json: { message: response[:message] }
    end
  end

  def destroy
    @hook.destroy!
    head :ok
  end

  def run_sync
    if @hook.disabled?
      render json: { message: 'Medelement hook must be enabled before running a sync' }, status: :unprocessable_content
      return
    end

    Integrations::Medelement::SyncJob.perform_later(@hook.id)
    render json: { message: 'Medelement sync queued successfully' }, status: :accepted
  end

  def import_catalog
    upload = params[:file]
    return render_import_error('missing_file', 'Select a JSON catalog file') unless upload.respond_to?(:read)
    return render_import_error('file_too_large', 'Catalog file must not exceed 5 MB', status: 413) if upload.size > MEDELEMENT_CATALOG_MAX_BYTES

    with_medelement_sync_lock do
      payload = JSON.parse(upload.read)
      result = Integrations::Medelement::CatalogImportService.new(
        account: Current.account,
        configuration: Integrations::Medelement::Configuration.new(hook: @hook),
        payload: payload
      ).perform

      render json: { message: 'Medelement catalog imported successfully', result: result }
    end
  rescue JSON::ParserError
    render_import_error('invalid_json', 'Catalog file must contain valid JSON')
  rescue Integrations::Medelement::CatalogImportService::InvalidPayloadError => e
    render_import_error('invalid_payload', e.message)
  end

  private

  def fetch_hook
    @hook = Current.account.hooks.find(params[:id])
  end

  def check_authorization
    authorize(:hook)
  end

  def permitted_params
    params.require(:hook).permit(:app_id, :inbox_id, :status, :access_token, settings: {}, secret_settings: {})
  end

  def normalized_params
    params = permitted_params.to_h
    secret_settings = compact_secret_settings(params.delete('secret_settings'))

    if secret_settings.present?
      existing_secret_settings = @hook&.secret_settings || {}
      params['access_token'] = existing_secret_settings.merge(secret_settings).to_json
    end

    if [true, false, 'true', 'false'].include?(params['status'])
      params['status'] = ActiveModel::Type::Boolean.new.cast(params['status']) ? 'enabled' : 'disabled'
    end

    params.delete('access_token') if params['access_token'].blank?
    params
  end

  def compact_secret_settings(secret_settings)
    return {} if secret_settings.blank?

    secret_settings.to_h.transform_values { |value| value.is_a?(String) ? value.strip : value }.compact_blank
  end

  def ensure_medelement_hook!
    raise ActiveRecord::RecordNotFound unless @hook.medelement?
  end

  def render_import_error(code, message, status: :unprocessable_content)
    render json: { code: code, message: message }, status: status
  end

  def with_medelement_sync_lock
    lock_manager = Redis::LockManager.new
    lock_key = format(Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: Current.account.id)
    acquired = lock_manager.lock(lock_key, MEDELEMENT_CATALOG_LOCK_TIMEOUT)
    return render_import_error('import_in_progress', 'Medelement catalog sync is already running', status: :conflict) unless acquired

    yield
  ensure
    lock_manager&.unlock(lock_key) if acquired
  end
end
