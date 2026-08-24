class Api::V1::Accounts::Integrations::HooksController < Api::V1::Accounts::BaseController
  MEDELEMENT_CATALOG_MAX_BYTES = 5.megabytes
  MEDELEMENT_CATALOG_LOCK_TIMEOUT = 10.minutes

  before_action :fetch_hook, except: [:create]
  before_action :check_authorization
  before_action :ensure_medelement_hook!, only: [:run_sync, :sync_status, :sync_conflict, :resolve_sync_conflict, :import_catalog]

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

    run, enqueued = Integrations::Medelement::SyncRunLauncher.new(
      hook: @hook,
      requested_by: Current.user,
      phases: params[:phases]
    ).perform
    message = enqueued ? 'Medelement sync queued successfully' : 'Medelement sync is already running'
    render json: {
      message: message,
      sync_status: medelement_sync_status(run: run)
    }, status: :accepted
  rescue ArgumentError => e
    render json: { code: 'invalid_phases', message: e.message }, status: :unprocessable_content
  end

  def sync_status
    render json: medelement_sync_status
  end

  def sync_conflict
    conflict = medelement_conflict!

    case params[:resolution]
    when 'ignore'
      conflict.ignore!(user: Current.user)
    when 'reopen'
      conflict.reopen!
    else
      return render json: {
        code: 'invalid_resolution',
        message: 'Resolution must be ignore or reopen'
      }, status: :unprocessable_content
    end

    render json: medelement_sync_status
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def resolve_sync_conflict
    conflict = medelement_conflict!
    service = Integrations::Medelement::ContactResolutionService.new(conflict: conflict, user: Current.user)

    case params[:resolution]
    when 'merge'
      service.merge_contacts!(base_contact_id: params[:base_contact_id], mergee_contact_id: params[:mergee_contact_id])
    when 'delete'
      service.delete!(contact_id: params[:contact_id])
    when 'keep_separate'
      service.keep_separate!(note: params[:note])
    when 'sync_fields'
      Integrations::Medelement::ContactFieldResolutionService.new(
        conflict: conflict,
        user: Current.user
      ).perform(field_directions: params[:field_directions])
    else
      return render json: { code: 'invalid_resolution', message: 'Unsupported contact conflict resolution' },
                    status: :unprocessable_content
    end

    render json: medelement_sync_status
  rescue Integrations::Medelement::ContactFieldResolutionService::FieldAlreadyUsedError => e
    render json: {
      code: 'contact_field_already_used',
      field: e.field,
      contact_id: e.contact_id,
      message: e.message
    }, status: :unprocessable_content
  rescue Integrations::Medelement::ContactResolutionService::UnsafeDeletionError,
         Integrations::Medelement::ContactResolutionService::UnsupportedConflictError,
         Integrations::Medelement::ContactFieldResolutionService::ResolutionError,
         Contacts::ReferenceMergeService::UnsafeMergeError,
         ArgumentError => e
    render json: { code: 'unsafe_resolution', message: e.message }, status: :unprocessable_content
  end

  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
  def import_catalog
    upload = params[:file]
    return render_import_error('missing_file', 'Select a JSON catalog file') unless upload.respond_to?(:read)
    return render_import_error('file_too_large', 'Catalog file must not exceed 5 MB', status: 413) if upload.size > MEDELEMENT_CATALOG_MAX_BYTES

    with_medelement_sync_lock do
      payload = JSON.parse(upload.read)
      result = Integrations::Medelement::CatalogImportService.new(
        hook: @hook,
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

  def medelement_sync_status(run: nil)
    presenter = Integrations::Medelement::SyncStatusPresenter.new(
      hook: @hook,
      conflict_page: params[:conflict_page],
      filters: params.permit(:status, :conflict_type, :from, :to, :contact)
    )
    run ? presenter.payload(run: run) : presenter.payload
  end

  def medelement_conflict!
    Integrations::Medelement::SyncConflict.find_by!(
      id: params[:conflict_id],
      account_id: Current.account.id,
      hook_id: @hook.id
    )
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
