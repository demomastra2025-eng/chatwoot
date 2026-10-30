# frozen_string_literal: true

class Api::V1::OwnerFinance::AccountsController < Api::V1::OwnerFinance::BaseController
  before_action :set_account_record, only: %i[update destroy]

  def create
    record = OwnerFinance::AccountRecord.create!(account_params)
    render json: OwnerFinance::RecordSerializer.account(record), status: :created
  end

  def update
    @account_record.update!(account_params)
    render json: OwnerFinance::RecordSerializer.account(@account_record)
  end

  def destroy
    @account_record.destroy!
    head :no_content
  end

  private

  def set_account_record
    @account_record = OwnerFinance::AccountRecord.find(params[:id])
  end

  def account_params
    params.require(:account).permit(
      :name, :account_kind, :bank_code, :currency, :current_balance, :scope, :active, :notes
    )
  end
end
