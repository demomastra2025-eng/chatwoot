class Crm::StageVisits::ReconciliationService
  def initialize(account: nil, auto_fix: false, occurred_at: Time.current)
    @account = account
    @auto_fix = auto_fix
    @occurred_at = occurred_at
  end

  def perform
    report = { checked: 0, missing: [], mismatched: [], multiple_active: [], fixed: [] }

    deal_scope.find_each do |deal|
      report[:checked] += 1
      reconcile_deal(deal, report)
    end

    report
  end

  private

  attr_reader :account, :auto_fix, :occurred_at

  def deal_scope
    scope = Crm::Deal.includes(:stage, :pipeline)
    account.present? ? scope.where(account_id: account.id) : scope
  end

  def reconcile_deal(deal, report)
    active_visits = deal.stage_visits.active.to_a
    return reconcile_missing_visit(deal, report) if active_visits.empty?
    return report_multiple_visits(deal, active_visits, report) if active_visits.many?

    report_mismatched_visit(deal, active_visits.first, report)
  end

  def reconcile_missing_visit(deal, report)
    report[:missing] << deal.id
    fix_missing_visit(deal, report) if auto_fix
  end

  def report_multiple_visits(deal, visits, report)
    report[:multiple_active] << { deal_id: deal.id, visit_ids: visits.map(&:id) }
  end

  def report_mismatched_visit(deal, active_visit, report)
    return if active_visit.stage_id == deal.stage_id && active_visit.pipeline_id == deal.pipeline_id

    report[:mismatched] << {
      deal_id: deal.id,
      visit_id: active_visit.id,
      visit_stage_id: active_visit.stage_id,
      deal_stage_id: deal.stage_id
    }
  end

  def fix_missing_visit(deal, report)
    deal.with_lock do
      visit = Crm::StageVisits::Tracker.ensure_initial!(
        deal: deal,
        correlation_id: SecureRandom.uuid,
        occurred_at: occurred_at,
        estimated: true
      )
      report[:fixed] << { deal_id: deal.id, visit_id: visit.id }
    end
  end
end
