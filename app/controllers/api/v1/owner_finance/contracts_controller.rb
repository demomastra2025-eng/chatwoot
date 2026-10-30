# frozen_string_literal: true

class Api::V1::OwnerFinance::ContractsController < Api::V1::OwnerFinance::BaseController
  before_action :set_contract, only: %i[update destroy]

  def create
    record = OwnerFinance::Contract.create!(contract_params)
    render json: serialize_contract(record), status: :created
  end

  def update
    @contract.update!(contract_params)
    render json: serialize_contract(@contract)
  end

  def destroy
    @contract.destroy!
    head :no_content
  end

  private

  def set_contract
    @contract = OwnerFinance::Contract.find(params[:id])
  end

  def serialize_contract(record)
    acct = record.onelink_account_id.present? ? Account.find_by(id: record.onelink_account_id) : nil
    OwnerFinance::RecordSerializer.contract(record, acct)
  end

  def contract_params
    params.require(:contract).permit(
      :client_name, :contract_number, :title, :status, :tariff_code, :monthly_amount,
      :one_time_amount, :currency, :billing_day, :starts_on, :ends_on,
      :medelement_commission_enabled, :medelement_commission_rate, :onelink_account_id,
      :counterparty_id, :notes
    )
  end
end
