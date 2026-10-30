# frozen_string_literal: true

class Api::V1::OwnerFinance::DashboardsController < Api::V1::OwnerFinance::BaseController
  def show
    payload = OwnerFinance::DashboardQueryService.new(
      year: params[:year],
      month: params[:month]
    ).perform
    render json: payload
  end
end
