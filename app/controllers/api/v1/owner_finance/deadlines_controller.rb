# frozen_string_literal: true

class Api::V1::OwnerFinance::DeadlinesController < Api::V1::OwnerFinance::BaseController
  before_action :set_deadline, only: %i[update destroy complete]

  def create
    record = OwnerFinance::Deadline.create!(deadline_params)
    render json: OwnerFinance::RecordSerializer.deadline(record), status: :created
  end

  def update
    @deadline.update!(deadline_params)
    render json: OwnerFinance::RecordSerializer.deadline(@deadline)
  end

  def destroy
    @deadline.destroy!
    head :no_content
  end

  def complete
    @deadline.advance_or_complete!
    render json: OwnerFinance::RecordSerializer.deadline(@deadline)
  end

  def run_reminders
    render json: OwnerFinance::DeadlineReminderService.new.perform
  end

  private

  def set_deadline
    @deadline = OwnerFinance::Deadline.find(params[:id])
  end

  def deadline_params
    params.require(:deadline).permit(
      :title, :category, :payer_mode, :provider, :related_domain, :client_name,
      :counterparty_id, :contract_id, :due_on, :amount, :currency, :recurrence,
      :status, :notes, remind_days: []
    )
  end
end
