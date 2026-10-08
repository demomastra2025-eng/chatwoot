# frozen_string_literal: true

class Api::V1::Accounts::StorageController < Api::V1::Accounts::BaseController
  TRASH_ITEM_TYPES = %w[recording original_recording attachment].freeze
  DEFAULT_CLEANUP_MONTHS = 6

  before_action :check_admin_authorization?

  rescue_from Storage::TrashService::InvalidParams, with: :render_invalid_params
  rescue_from Accounts::HeavyFilesService::InvalidParams, with: :render_invalid_params
  rescue_from Accounts::HeavyFilesService::AttachmentTimeout, with: :render_heavy_files_timeout

  def show
    snapshot = storage_overview.schedule_refresh
    render json: { storage: storage_payload(snapshot) }
  end

  def heavy_files
    service = Accounts::HeavyFilesService.new(
      account: current_account,
      params: params.permit(:file_type, :inbox_id, :conversation_id, :date_from, :date_to, :limit)
    )
    files = service.perform
    render json: { files: files, recordings_pending: service.recordings_pending? }
  end

  def refresh
    snapshot = storage_overview.schedule_refresh(force: true)
    render json: { success: true, storage: storage_payload(snapshot) }
  end

  def preview_cleanup
    service = Storage::TrashService.new(account: current_account, actor_id: current_user.id)
    result = service.preview(
      file_type: params[:file_type] || 'all',
      older_than_months: params.fetch(:older_than_months, DEFAULT_CLEANUP_MONTHS),
      inbox_id: params[:inbox_id].presence
    )
    render json: result
  end

  def move_to_trash
    service = Storage::TrashService.new(account: current_account, actor_id: current_user.id)
    filters = {
      file_type: params[:file_type] || 'all',
      older_than_months: params.fetch(:older_than_months, DEFAULT_CLEANUP_MONTHS),
      inbox_id: params[:inbox_id].presence
    }
    result = service.move_to_trash!(
      **filters, preview_token: params[:preview_token], confirmed: params[:confirmed]
    )
    audit_storage_action!(
      'storage_move_to_trash',
      filters.merge(count: result[:moved_count], bytes: result[:moved_bytes])
    )
    render json: result
  end

  def trash
    service = Storage::TrashService.new(account: current_account, actor_id: current_user.id)
    result = service.list_trash(
      page: (params[:page] || 1).to_i,
      limit: (params[:limit] || 50).to_i
    )
    render json: result
  end

  def restore_trash
    restore_all = ActiveModel::Type::Boolean.new.cast(params[:restore_all])
    validate_trash_item! unless restore_all

    audit_storage_action!('storage_restore_trash', { item_type: params[:item_type], item_id: params[:item_id], restore_all: restore_all })
    service = Storage::TrashService.new(account: current_account, actor_id: current_user.id)
    result = service.restore!(item_type: params[:item_type], item_id: params[:item_id], restore_all: restore_all)
    render json: result
  end

  # DELETE without item_type/item_id empties the whole trash; a single item needs both. A request that
  # names only one of them is rejected instead of silently turning into "purge everything".
  def empty_trash
    purge_all = params[:item_type].blank? && params[:item_id].blank?
    validate_trash_item! unless purge_all
    require_trash_confirmation!

    result = storage_trash_service.empty_trash!(
      item_type: params[:item_type], item_id: params[:item_id], purge_all: purge_all
    )
    audit_storage_action!('storage_purge_trash', trash_purge_details(purge_all))
    render json: result
  end

  private

  def storage_overview
    @storage_overview ||= Accounts::StorageOverviewService.new(account: current_account)
  end

  def storage_payload(snapshot)
    return { calculating: true, breakdown: nil, last_updated_at: nil } if snapshot.nil?

    limits = snapshot[:limits]
    breakdown = snapshot[:breakdown]
    {
      total_limit_bytes: limits[:total_count],
      consumed_bytes: limits[:consumed],
      available_bytes: limits[:current_available],
      unlimited: limits[:unlimited],
      usage_percent: calculate_percentage(limits[:consumed], limits[:total_count], limits[:unlimited]),
      breakdown: breakdown,
      last_updated_at: breakdown[:last_updated_at],
      calculating: false
    }
  end

  def storage_trash_service
    Storage::TrashService.new(account: current_account, actor_id: current_user.id)
  end

  def require_trash_confirmation!
    return if ActiveModel::Type::Boolean.new.cast(params[:confirmed])

    raise Storage::TrashService::InvalidParams, I18n.t('storage_management.errors.confirmation_required')
  end

  def trash_purge_details(purge_all)
    { item_type: params[:item_type], item_id: params[:item_id], purge_all: purge_all }
  end

  def validate_trash_item!
    return if TRASH_ITEM_TYPES.include?(params[:item_type].to_s) && params[:item_id].present?

    raise Storage::TrashService::InvalidParams, I18n.t('storage_management.errors.trash_item_required')
  end

  def render_invalid_params(error)
    render json: { message: error.message }, status: :unprocessable_entity
  end

  def render_heavy_files_timeout(error)
    render json: { message: error.message }, status: :service_unavailable
  end

  def audit_storage_action!(action, changes)
    Audited::Audit.create!(
      auditable: current_account, associated: current_account, action: action,
      audited_changes: changes.compact.stringify_keys, user: current_user,
      remote_address: request.remote_ip, request_uuid: request.request_id, comment: 'account_storage'
    )
  end

  def calculate_percentage(consumed, total, unlimited)
    return 0.0 if unlimited || total.to_i.zero? || total == ChatwootApp.max_limit.to_i

    (consumed.to_f / total * 100).round(1)
  end
end
