# frozen_string_literal: true

class Api::V1::Accounts::StorageController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?

  def show
    breakdown = current_account.storage_breakdown
    limits = AccountLimits::StorageUsageService.new(account: current_account).summary

    render json: {
      storage: {
        total_limit_bytes: limits[:total_count],
        consumed_bytes: limits[:consumed],
        available_bytes: limits[:current_available],
        unlimited: limits[:unlimited],
        usage_percent: calculate_percentage(limits[:consumed], limits[:total_count], limits[:unlimited]),
        breakdown: breakdown,
        last_updated_at: breakdown[:last_updated_at]
      }
    }
  end

  def heavy_files
    service = Accounts::HeavyFilesService.new(
      account: current_account,
      params: params.permit(:file_type, :inbox_id, :limit)
    )
    render json: { files: service.perform }
  end

  def refresh
    breakdown = current_account.storage_breakdown(force_refresh: true)
    limits = AccountLimits::StorageUsageService.new(account: current_account).summary

    render json: {
      success: true,
      storage: {
        total_limit_bytes: limits[:total_count],
        consumed_bytes: limits[:consumed],
        available_bytes: limits[:current_available],
        unlimited: limits[:unlimited],
        usage_percent: calculate_percentage(limits[:consumed], limits[:total_count], limits[:unlimited]),
        breakdown: breakdown,
        last_updated_at: breakdown[:last_updated_at]
      }
    }
  end

  def preview_cleanup
    service = Storage::TrashService.new(account: current_account)
    result = service.preview(
      file_type: params[:file_type] || 'all',
      older_than_months: (params[:older_than_months] || 6).to_i,
      inbox_id: params[:inbox_id].presence
    )
    render json: result
  end

  def move_to_trash
    service = Storage::TrashService.new(account: current_account)
    result = service.move_to_trash!(
      file_type: params[:file_type] || 'all',
      older_than_months: (params[:older_than_months] || 6).to_i,
      inbox_id: params[:inbox_id].presence
    )
    render json: result
  end

  def trash
    service = Storage::TrashService.new(account: current_account)
    result = service.list_trash(
      page: (params[:page] || 1).to_i,
      limit: (params[:limit] || 50).to_i
    )
    render json: result
  end

  def restore_trash
    service = Storage::TrashService.new(account: current_account)
    result = service.restore!(
      item_type: params[:item_type],
      item_id: params[:item_id],
      restore_all: ActiveModel::Type::Boolean.new.cast(params[:restore_all])
    )
    render json: result
  end

  def empty_trash
    service = Storage::TrashService.new(account: current_account)
    result = service.empty_trash!(
      item_type: params[:item_type],
      item_id: params[:item_id],
      purge_all: params[:item_id].blank?
    )
    render json: result
  end

  private

  def calculate_percentage(consumed, total, unlimited)
    return 0.0 if unlimited || total.to_i.zero? || total == ChatwootApp.max_limit.to_i

    [((consumed.to_f / total) * 100).round(1), 100.0].min
  end
end
