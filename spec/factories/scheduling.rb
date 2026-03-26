# frozen_string_literal: true

FactoryBot.define do
  factory :scheduling_resource, class: 'Scheduling::Resource' do
    account
    sequence(:name) { |n| "Resource #{n}" }
    timezone { Scheduling::Constants::DEFAULT_TIMEZONE }
    slot_duration_min { 30 }
    compensation_type { 'percent' }
    compensation_value { 40 }
    compensation_percent { 0 }
    active { true }
  end

  factory :scheduling_work_rule, class: 'Scheduling::WorkRule' do
    account { resource.account }
    resource { association :scheduling_resource }
    weekday { 1 }
    start_minute { 9 * 60 }
    end_minute { 18 * 60 }
    active { true }
  end

  factory :scheduling_break_rule, class: 'Scheduling::BreakRule' do
    account { resource.account }
    resource { association :scheduling_resource }
    weekday { 1 }
    start_minute { 13 * 60 }
    end_minute { 14 * 60 }
    title { 'Lunch' }
    active { true }
  end

  factory :scheduling_holiday, class: 'Scheduling::Holiday' do
    account
    date { Date.current }
    title { 'Holiday' }
    recurring_yearly { false }
    working_day_override { false }
  end

  factory :scheduling_workday_override, class: 'Scheduling::WorkdayOverride' do
    account { resource.account }
    resource { association :scheduling_resource }
    date { Date.current }
    start_minute { 10 * 60 }
    end_minute { 16 * 60 }
    break_start_minute { nil }
    break_end_minute { nil }
  end

  factory :scheduling_time_off, class: 'Scheduling::TimeOff' do
    account { resource.account }
    resource { association :scheduling_resource }
    kind { 'vacation' }
    starts_at { Time.zone.now.change(hour: 12, min: 0, sec: 0) }
    ends_at { starts_at + 2.hours }
    title { 'Vacation' }
  end

  factory :scheduling_service, class: 'Scheduling::Service' do
    account
    sequence(:name) { |n| "Service #{n}" }
    base_price { 15_000 }
    duration_min { 30 }
    active { true }
  end

  factory :scheduling_service_price, class: 'Scheduling::ServicePrice' do
    account { service.account }
    service { association :scheduling_service }
    resource { association :scheduling_resource, account: service.account }
    price { 20_000 }
    compensation_type { 'percent' }
    compensation_value { 50 }
    compensation_percent { 0 }
    active { true }
  end

  factory :scheduling_appointment, class: 'Scheduling::Appointment' do
    account { resource.account }
    resource { association :scheduling_resource }
    contact { association :contact, account: resource.account }
    service { association :scheduling_service, account: resource.account }
    starts_at { Time.zone.now.change(hour: 10, min: 0, sec: 0) }
    ends_at { starts_at + 30.minutes }
    duration_min { 30 }
    status { 'scheduled' }
    appointment_type { 'primary' }
    client_name { contact.name }
    client_phone { contact.phone_number }
    client_identifier { contact.identifier }
    source { 'manual' }
    service_name_snapshot { service&.name }
    service_type_snapshot { service&.service_type }
    service_duration_min_snapshot { service&.duration_min }
    service_amount { service&.base_price || 0 }
    compensation_type_snapshot { resource.compensation_type }
    compensation_value_snapshot { resource.compensation_value }
    compensation_percent_snapshot { resource.compensation_percent }
    prepaid_amount { 0 }
    settlement_amount { 0 }
    payment_status { 'awaiting_payment' }
  end

  factory :scheduling_payment, class: 'Scheduling::Payment' do
    account { appointment.account }
    appointment { association :scheduling_appointment }
    amount { 5_000 }
    payment_method { 'cash' }
    payment_kind { 'payment' }
  end

  factory :scheduling_expense, class: 'Scheduling::Expense' do
    account { appointment.account }
    appointment { association :scheduling_appointment }
    resource { appointment.resource }
    amount { 6_000 }
    status { 'unpaid' }
  end
end
