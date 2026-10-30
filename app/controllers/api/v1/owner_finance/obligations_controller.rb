# frozen_string_literal: true

class Api::V1::OwnerFinance::ObligationsController < Api::V1::OwnerFinance::BaseController
  before_action :set_obligation, only: %i[update destroy]

  def create
    record = OwnerFinance::Obligation.create!(obligation_params)
    render json: OwnerFinance::RecordSerializer.obligation(record), status: :created
  end

  def update
    @obligation.update!(obligation_params)
    render json: OwnerFinance::RecordSerializer.obligation(@obligation)
  end

  def destroy
    @obligation.destroy!
    head :no_content
  end

  private

  def set_obligation
    @obligation = OwnerFinance::Obligation.find(params[:id])
  end

  def obligation_params
    params.require(:obligation).permit(
      :entry_kind, :title, :counterparty_name, :contract_id, :period_label,
      :base_amount, :overage_excluded_amount, :amount, :paid_amount, :currency,
      :due_on, :paid_on, :status, :notes
    )
  end
end
