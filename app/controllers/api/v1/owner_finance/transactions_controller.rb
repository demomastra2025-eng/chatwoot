# frozen_string_literal: true

class Api::V1::OwnerFinance::TransactionsController < Api::V1::OwnerFinance::BaseController
  before_action :set_transaction, only: %i[update destroy hide_personal]

  def create
    record = OwnerFinance::TransactionRecord.new(transaction_params)
    record.review_status = 'confirmed' if record.review_status.blank?
    record.save!
    learn_counterparty_rule!(record) if ActiveModel::Type::Boolean.new.cast(params[:learn_vendor])
    render json: OwnerFinance::RecordSerializer.transaction(record), status: :created
  end

  def update
    was_needs_review = @transaction.review_status == 'needs_review'
    @transaction.update!(transaction_params)
    learn_counterparty_rule!(@transaction) if should_learn_vendor?(was_needs_review)
    render json: OwnerFinance::RecordSerializer.transaction(@transaction)
  end

  def destroy
    @transaction.destroy!
    head :no_content
  end

  def hide_personal
    result = OwnerFinance::PersonalHideService.new(
      transaction: @transaction,
      hide_merchant_always: params[:hide_merchant_always]
    ).perform
    render json: result
  end

  private

  def set_transaction
    @transaction = OwnerFinance::TransactionRecord.find(params[:id])
  end

  def should_learn_vendor?(was_needs_review)
    return ActiveModel::Type::Boolean.new.cast(params[:learn_vendor]) if params.key?(:learn_vendor)

    was_needs_review && @transaction.review_status == 'confirmed'
  end

  def transaction_params
    params.require(:transaction).permit(
      :occurred_on, :direction, :pnl_treatment, :official_status, :review_status,
      :amount, :currency, :amount_kzt, :category, :merchant, :description,
      :account_record_id, :counterparty_id, :contract_id
    )
  end

  def learn_counterparty_rule!(record)
    norm_key = OwnerFinance.normalize_merchant_key(record.merchant)
    return if norm_key.blank? || record.category.blank? || record.category == 'unclassified_card'

    counterparty = OwnerFinance::Counterparty.find_or_initialize_by(normalized_key: norm_key)
    counterparty.display_name = record.merchant if counterparty.display_name.blank?
    counterparty.kind = (record.direction == 'income' ? 'client' : 'vendor') if counterparty.new_record?
    counterparty.default_category = record.category
    counterparty.default_pnl_treatment = record.pnl_treatment
    counterparty.save!
  end
end
