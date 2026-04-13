module Scheduling::PayloadBuilder
  module_function

  def appointment(appointment, payments: nil, expense_record: nil)
    {
      id: appointment.id,
      account_id: appointment.account_id,
      resource_id: appointment.resource_id,
      contact_id: appointment.contact_id,
      service_id: appointment.service_id,
      service_ids: appointment.custom_attributes['service_ids'].presence || Array(appointment.service_id).compact,
      services: appointment.custom_attributes['services'].presence || [],
      company_id: appointment.company_id,
      conversation_id: appointment.conversation_id,
      created_by_id: appointment.created_by_id,
      service_name_snapshot: appointment.service_name_snapshot,
      service_type_snapshot: appointment.service_type_snapshot,
      service_duration_min_snapshot: appointment.service_duration_min_snapshot,
      starts_at: appointment.starts_at&.iso8601,
      ends_at: appointment.ends_at&.iso8601,
      duration_min: appointment.duration_min,
      status: appointment.status,
      appointment_type: appointment.appointment_type,
      client_name: appointment.client_name,
      client_phone: appointment.client_phone,
      client_identifier: appointment.client_identifier,
      client_birth_date: appointment.client_birth_date&.iso8601,
      client_gender: appointment.client_gender,
      client_comment: appointment.client_comment,
      source: appointment.source,
      external_ref: appointment.external_ref,
      idempotency_key: appointment.idempotency_key,
      service_amount: appointment.service_amount,
      compensation_type_snapshot: appointment.compensation_type_snapshot,
      compensation_value_snapshot: appointment.compensation_value_snapshot,
      compensation_percent_snapshot: appointment.compensation_percent_snapshot,
      prepaid_amount: appointment.prepaid_amount,
      prepaid_payment_method: appointment.prepaid_payment_method,
      settlement_amount: appointment.settlement_amount,
      settlement_payment_method: appointment.settlement_payment_method,
      payment_status: appointment.payment_status,
      custom_attributes: appointment.custom_attributes,
      payments: Array(payments || appointment.try(:payments)).map { |item| payment(item) },
      expense: if expense_record
                 expense(expense_record)
               else
                 (appointment.try(:expense).present? ? expense(appointment.expense) : nil)
               end,
      created_at: appointment.created_at&.iso8601,
      updated_at: appointment.updated_at&.iso8601
    }
  end

  def break_rule(rule)
    {
      id: rule.id,
      account_id: rule.account_id,
      resource_id: rule.resource_id,
      weekday: rule.weekday,
      start_minute: rule.start_minute,
      end_minute: rule.end_minute,
      title: rule.title,
      active: rule.active,
      created_at: rule.created_at&.iso8601,
      updated_at: rule.updated_at&.iso8601
    }
  end

  def calendar(payload)
    {
      view: payload[:view],
      range: payload[:range],
      resources: payload[:resources].map { |item| resource(item) },
      work_rules: payload[:work_rules].map { |item| work_rule(item) },
      break_rules: payload[:break_rules].map { |item| break_rule(item) },
      holidays: payload[:holidays].map { |item| holiday(item) },
      workday_overrides: payload[:workday_overrides].map { |item| workday_override(item) },
      time_offs: payload[:time_offs].map { |item| time_off(item) },
      appointments: payload[:appointments].map { |item| appointment(item) },
      payments: payload[:payments].map { |item| payment(item) },
      expenses: payload[:expenses].map { |item| expense(item) },
      slots: payload[:slots]
    }
  end

  def contact(contact)
    {
      id: contact.id,
      account_id: contact.account_id,
      company_id: contact.company_id,
      full_name: contact.name,
      phone: contact.phone_number,
      identifier: contact.identifier.presence || contact.custom_attributes['iin'],
      birth_date: contact.custom_attributes['birth_date'],
      gender: contact.custom_attributes['gender'],
      custom_attributes: contact.custom_attributes,
      created_at: contact.created_at&.iso8601,
      updated_at: contact.updated_at&.iso8601
    }
  end

  def expense(expense)
    {
      id: expense.id,
      account_id: expense.account_id,
      appointment_id: expense.appointment_id,
      resource_id: expense.resource_id,
      amount: expense.amount,
      status: expense.status,
      paid_at: expense.paid_at&.iso8601,
      paid_by_id: expense.paid_by_id,
      created_at: expense.created_at&.iso8601,
      updated_at: expense.updated_at&.iso8601
    }
  end

  def holiday(holiday)
    {
      id: holiday.id,
      account_id: holiday.account_id,
      date: holiday.date&.iso8601,
      title: holiday.title,
      recurring_yearly: holiday.recurring_yearly,
      working_day_override: holiday.working_day_override,
      custom_attributes: holiday.custom_attributes,
      created_at: holiday.created_at&.iso8601,
      updated_at: holiday.updated_at&.iso8601
    }
  end

  def payment(payment)
    {
      id: payment.id,
      account_id: payment.account_id,
      appointment_id: payment.appointment_id,
      recorded_by_id: payment.recorded_by_id,
      amount: payment.amount,
      payment_method: payment.payment_method,
      payment_kind: payment.payment_kind,
      created_at: payment.created_at&.iso8601,
      updated_at: payment.updated_at&.iso8601
    }
  end

  def resource(resource)
    {
      id: resource.id,
      account_id: resource.account_id,
      user_id: resource.user_id,
      name: resource.name,
      specialty: resource.specialty,
      photo_url: resource.photo_url,
      description: resource.description,
      color: resource.color,
      timezone: resource.timezone,
      slot_duration_min: resource.slot_duration_min,
      compensation_type: resource.compensation_type,
      compensation_value: resource.compensation_value,
      compensation_percent: resource.compensation_percent,
      active: resource.active,
      custom_attributes: resource.custom_attributes,
      created_at: resource.created_at&.iso8601,
      updated_at: resource.updated_at&.iso8601
    }
  end

  def service(service)
    {
      id: service.id,
      account_id: service.account_id,
      name: service.name,
      base_price: service.base_price,
      duration_min: service.duration_min,
      category: service.category,
      direction: service.direction,
      service_type: service.service_type,
      description: service.description,
      active: service.active,
      custom_attributes: service.custom_attributes,
      prices: Array(service.try(:prices)).map { |item| service_price(item) },
      created_at: service.created_at&.iso8601,
      updated_at: service.updated_at&.iso8601
    }
  end

  def service_price(price)
    {
      id: price.id,
      account_id: price.account_id,
      service_id: price.service_id,
      resource_id: price.resource_id,
      price: price.price,
      compensation_type: price.compensation_type,
      compensation_value: price.compensation_value,
      compensation_percent: price.compensation_percent,
      active: price.active,
      created_at: price.created_at&.iso8601,
      updated_at: price.updated_at&.iso8601
    }
  end

  def time_off(time_off)
    {
      id: time_off.id,
      account_id: time_off.account_id,
      resource_id: time_off.resource_id,
      kind: time_off.kind,
      starts_at: time_off.starts_at&.iso8601,
      ends_at: time_off.ends_at&.iso8601,
      title: time_off.title,
      notes: time_off.notes,
      custom_attributes: time_off.custom_attributes,
      created_at: time_off.created_at&.iso8601,
      updated_at: time_off.updated_at&.iso8601
    }
  end

  def work_rule(rule)
    {
      id: rule.id,
      account_id: rule.account_id,
      resource_id: rule.resource_id,
      weekday: rule.weekday,
      start_minute: rule.start_minute,
      end_minute: rule.end_minute,
      active: rule.active,
      created_at: rule.created_at&.iso8601,
      updated_at: rule.updated_at&.iso8601
    }
  end

  def workday_override(item)
    {
      id: item.id,
      account_id: item.account_id,
      resource_id: item.resource_id,
      date: item.date&.iso8601,
      start_minute: item.start_minute,
      end_minute: item.end_minute,
      break_start_minute: item.break_start_minute,
      break_end_minute: item.break_end_minute,
      break_title: item.break_title,
      custom_attributes: item.custom_attributes,
      created_at: item.created_at&.iso8601,
      updated_at: item.updated_at&.iso8601
    }
  end
end
