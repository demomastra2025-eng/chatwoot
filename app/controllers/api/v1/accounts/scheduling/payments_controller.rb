class Api::V1::Accounts::Scheduling::PaymentsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :ensure_finance_enabled!
  before_action :check_admin_authorization?

  def index
    payments = Current.account.scheduling_payments.includes(:appointment).ordered
    payments = payments.where(payment_kind: parse_csv_ids(params[:payment_kinds])) if params[:payment_kinds].present?
    payments = payments.where(payment_method: parse_csv_ids(params[:payment_methods])) if params[:payment_methods].present?

    from = parse_datetime_param!(params[:from], field_name: 'from', required: false)
    to = parse_datetime_param!(params[:to], field_name: 'to', required: false)
    payments = payments.where('created_at >= ?', from) if from.present?
    payments = payments.where('created_at < ?', to) if to.present?

    if params[:resource_ids].present?
      payments = payments.joins(:appointment).where(scheduling_appointments: { resource_id: parse_csv_ids(params[:resource_ids]) })
    end

    render_payload(payments.map { |payment| Scheduling::PayloadBuilder.payment(payment) }, meta: { count: payments.size })
  end
end
