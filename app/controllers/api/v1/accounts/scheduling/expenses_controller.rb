class Api::V1::Accounts::Scheduling::ExpensesController < Api::V1::Accounts::Scheduling::BaseController
  before_action :ensure_finance_enabled!
  before_action :check_admin_authorization?
  before_action :set_expense, only: [:pay]

  def index
    expenses = Current.account.scheduling_expenses.includes(:appointment).ordered
    expenses = expenses.where(status: parse_csv_ids(params[:status])) if params[:status].present?

    expenses = expenses.where(resource_id: parse_csv_ids(params[:resource_ids])) if params[:resource_ids].present?

    from = parse_datetime_param!(params[:from], field_name: 'from', required: false)
    to = parse_datetime_param!(params[:to], field_name: 'to', required: false)
    if from.present? || to.present?
      expenses = expenses.joins(:appointment)
      expenses = expenses.where('scheduling_appointments.starts_at >= ?', from) if from.present?
      expenses = expenses.where('scheduling_appointments.starts_at < ?', to) if to.present?
    end

    render_payload(expenses.map { |expense| Scheduling::PayloadBuilder.expense(expense) }, meta: { count: expenses.size })
  end

  def pay
    @expense.update!(
      status: 'paid',
      paid_at: @expense.paid_at || Time.zone.now,
      paid_by: Current.user
    )

    render_payload(Scheduling::PayloadBuilder.expense(@expense))
  end

  def pay_all
    expenses = filtered_unpaid_expenses

    ApplicationRecord.transaction do
      expenses.each do |expense|
        expense.update!(
          status: 'paid',
          paid_at: expense.paid_at || Time.zone.now,
          paid_by: Current.user
        )
      end
    end

    render_payload(expenses.map { |expense| Scheduling::PayloadBuilder.expense(expense) }, meta: { count: expenses.size })
  end

  private

  def filtered_unpaid_expenses
    expenses = Current.account.scheduling_expenses.includes(:appointment).where(status: 'unpaid').ordered
    expenses = expenses.where(resource_id: parse_csv_ids(params[:resource_ids])) if params[:resource_ids].present?

    from = parse_datetime_param!(params[:from], field_name: 'from', required: false)
    to = parse_datetime_param!(params[:to], field_name: 'to', required: false)
    return expenses unless from.present? || to.present?

    expenses = expenses.joins(:appointment)
    expenses = expenses.where('scheduling_appointments.starts_at >= ?', from) if from.present?
    expenses = expenses.where('scheduling_appointments.starts_at < ?', to) if to.present?
    expenses
  end

  def set_expense
    @expense = Current.account.scheduling_expenses.find(params[:id])
  end
end
