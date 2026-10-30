# frozen_string_literal: true

class Api::V1::OwnerFinance::OnecSyncsController < Api::V1::OwnerFinance::BaseController
  def create
    days_back = (params[:days_back].presence || 45).to_i.clamp(1, 365)
    result = OwnerFinance::OnecFreshSyncService.new(days_back: days_back).perform
    render json: result
  rescue StandardError => e
    render json: { error: e.message, status: 'error' }, status: :unprocessable_content
  end
end
