# frozen_string_literal: true

class Scheduling::TemplateFieldFillStats
  # A field is unsafe when at least one in ten upcoming visits lacks a value.
  BLOCKING_EMPTY_SHARE = 0.1

  def initialize(account:, field_ids:, rule: nil)
    @account = account
    available = Captain::ContextFields.field_ids_for(account).grep(/\Aappointment\./)
    @field_ids = Array(field_ids).map(&:to_s).uniq & available
    @rule = rule
  end

  def perform
    counts = field_ids.index_with { { total: 0, empty: 0 } }
    upcoming_visits.find_each { |visit| count_visit(visit, counts) }
    counts.map { |field_id, count| result_for(field_id, count) }
  end

  private

  attr_reader :account, :field_ids, :rule

  def upcoming_visits
    account.scheduling_appointments.where(status: %w[scheduled confirmed]).where('starts_at > ?', Time.current)
  end

  def count_visit(visit, counts)
    return if rule && !AutomationRules::AppointmentConditionService.new(rule, visit).perform

    renderer = FieldReferences::RendererService.new(account: account, appointment: visit)
    field_ids.each do |field_id|
      counts[field_id][:total] += 1
      counts[field_id][:empty] += 1 if renderer.render("[value](field://#{field_id})").blank?
    end
  end

  def result_for(field_id, count)
    share = count[:total].positive? ? count[:empty].fdiv(count[:total]) : 0.0
    { field_id: field_id, total: count[:total], empty: count[:empty], share: share,
      blocking: count[:empty].positive? && share >= BLOCKING_EMPTY_SHARE }
  end
end
