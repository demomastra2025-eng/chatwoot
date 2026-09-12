class Scheduling::CalendarViewService
  def initialize(account:, **options)
    @account = account
    @view = options.fetch(:view)
    @from = options.fetch(:from)
    @to = options.fetch(:to)
    @requested_resource_ids = Array(options[:resource_ids]).compact_blank
    filters = options.fetch(:filters, {})
    @statuses = Array(filters[:statuses]).compact_blank
    @payment_statuses = Array(filters[:payment_statuses]).compact_blank
    @include_slots = ActiveModel::Type::Boolean.new.cast(options[:include_slots])
    @duration_min = options[:duration_min].presence&.to_i
    @custom_attribute_filters = options[:custom_attribute_filters]
  end

  def perform
    {
      view: @view,
      range: {
        from: @from.iso8601,
        to: @to.iso8601
      },
      resources: resources,
      work_rules: work_rules,
      break_rules: break_rules,
      holidays: holidays,
      workday_overrides: workday_overrides,
      time_offs: time_offs,
      appointments: appointments,
      payments: payments,
      expenses: expenses,
      slots: slots
    }
  end

  private

  def appointments
    @appointments ||= begin
      scope = appointment_custom_field_filter_set.apply(base_appointments_scope)
      scope = scope.where(status: @statuses) if @statuses.present?
      scope = scope.where(payment_status: @payment_statuses) if @payment_statuses.present?
      scope.to_a
    end
  end

  def break_rules
    @break_rules ||= account.scheduling_break_rules.where(resource_id: resource_ids).ordered.to_a
  end

  def expenses
    @expenses ||= if appointment_ids.empty?
                    []
                  else
                    account.scheduling_expenses.where(appointment_id: appointment_ids).ordered.to_a
                  end
  end

  def holidays
    @holidays ||= account.scheduling_holidays.ordered.to_a
  end

  def payments
    @payments ||= if appointment_ids.empty?
                    []
                  else
                    account.scheduling_payments.where(appointment_id: appointment_ids).ordered.to_a
                  end
  end

  def resource_ids
    @resource_ids ||= resources.map(&:id)
  end

  def resources
    @resources ||= begin
      scope = account.scheduling_resources.not_deleted_from_scheduling.includes(:work_rules, :break_rules).ordered
      scope = scope.where(id: @requested_resource_ids) if @requested_resource_ids.present?
      resolved = scope.to_a
      missing_ids = @requested_resource_ids.map(&:to_i) - resolved.map(&:id)
      raise ActiveRecord::RecordNotFound, "Resources not found: #{missing_ids.join(', ')}" if missing_ids.present?

      resolved
    end
  end

  def slots
    return [] unless @include_slots

    resources.flat_map do |resource|
      availability_for(resource).slots(duration_min: @duration_min || resource.slot_duration_min)
    end
  end

  def time_offs
    @time_offs ||= account.scheduling_time_offs
                          .where(resource_id: [nil] + resource_ids)
                          .where('starts_at < ? AND ends_at > ?', @to, @from)
                          .ordered
                          .to_a
  end

  def work_rules
    @work_rules ||= account.scheduling_work_rules.where(resource_id: resource_ids).ordered.to_a
  end

  def workday_overrides
    @workday_overrides ||= account.scheduling_workday_overrides
                                  .where(resource_id: resource_ids, date: local_date_window)
                                  .ordered
                                  .to_a
  end

  attr_reader :account

  def appointment_ids
    @appointment_ids ||= appointments.map(&:id)
  end

  def availability_for(resource)
    Scheduling::AvailabilityService.new(
      resource: resource,
      from: @from,
      to: @to,
      holidays: holidays,
      workday_overrides: workday_overrides.select { |item| item.resource_id == resource.id },
      time_offs: time_offs.select { |item| item.resource_id.nil? || item.resource_id == resource.id },
      appointments: blocking_appointments.select { |item| item.resource_id == resource.id }
    )
  end

  def local_date_window
    (@from.to_date - 1)..(@to.to_date + 1)
  end

  def base_appointments_scope
    @base_appointments_scope ||= account.scheduling_appointments
                                        .includes(:expense, :payments, :contact, :resource,
                                                  conversation: [:communication_thread, :inbox])
                                        .where(resource_id: resource_ids)
                                        .where('starts_at < ? AND ends_at > ?', @to, @from)
                                        .ordered
  end

  def blocking_appointments
    @blocking_appointments ||= base_appointments_scope.to_a
  end

  def appointment_custom_field_filter_set
    @appointment_custom_field_filter_set ||= Scheduling::AppointmentCustomFieldFilterSet.new(
      account: account,
      raw_filters: @custom_attribute_filters
    )
  end
end
