class Scheduling::Appointments::FinanceSyncService
  def initialize(appointment:, actor: nil)
    @appointment = appointment
    @actor = actor
  end

  # Stage 3 MedElement flows still call these entry points to reconcile the expense only.
  def sync_expense_only!
    sync_expense!
    appointment.reload
  end

  def sync!
    sync_expense_only!
  end

  private

  attr_reader :actor, :appointment

  def compute_expense_amount
    return 0 if appointment.compensation_type_snapshot.blank?
    return appointment.compensation_value_snapshot.to_i if appointment.compensation_type_snapshot == 'fixed'
    return appointment.compensation_value_snapshot.to_i + percentage_expense_amount if appointment.compensation_type_snapshot == 'fixed_plus_percent'

    ((appointment.service_amount.to_i * appointment.compensation_value_snapshot.to_i) / 100.0).round
  end

  def percentage_expense_amount
    ((appointment.service_amount.to_i * appointment.compensation_percent_snapshot.to_i) / 100.0).round
  end

  def sync_expense!
    existing_expense = appointment.expense
    return remove_unpaid_expense!(existing_expense) unless appointment_paid?

    upsert_expense!(existing_expense)
  end

  def appointment_paid?
    appointment.payment_status == 'paid'
  end

  def remove_unpaid_expense!(existing_expense)
    existing_expense.destroy! if existing_expense.present? && existing_expense.status != 'paid'
    existing_expense
  end

  def upsert_expense!(existing_expense)
    return existing_expense if existing_expense.present? && existing_expense.status == 'paid'
    return update_existing_expense!(existing_expense) if existing_expense.present?

    appointment.create_expense!(
      account: appointment.account,
      resource: appointment.resource,
      amount: compute_expense_amount,
      status: 'unpaid'
    )
  end

  def update_existing_expense!(existing_expense)
    existing_expense.update!(
      resource: appointment.resource,
      amount: compute_expense_amount,
      status: 'unpaid'
    )
    existing_expense
  end
end
