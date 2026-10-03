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

  private

  def calculate_percentage(consumed, total, unlimited)
    return 0.0 if unlimited || total.to_i.zero? || total == ChatwootApp.max_limit.to_i

    [((consumed.to_f / total) * 100).round(1), 100.0].min
  end
end
