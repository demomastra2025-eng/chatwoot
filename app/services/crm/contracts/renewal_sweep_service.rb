# frozen_string_literal: true

class Crm::Contracts::RenewalSweepService
  EXPIRING_WINDOW_DAYS = 30
  RENEWAL_TASK_LEAD_DAYS = 7
  ASTANA_TIMEZONE = 'Asia/Almaty'

  def initialize(account: nil, reference_date: nil)
    @account = account
    @reference_date = reference_date || Time.current.in_time_zone(ASTANA_TIMEZONE).to_date
  end

  def perform
    report = { checked: 0, transitioned: [], tasks_created: [] }

    expiring_stages.find_each do |expiring_stage|
      process_pipeline(expiring_stage, report)
    end

    report
  end

  private

  attr_reader :account, :reference_date

  def expiring_stages
    scope = Crm::Stage.active.where(code: 'od_exec_expiring').includes(:pipeline, :account)
    account.present? ? scope.where(account_id: account.id) : scope
  end

  def process_pipeline(expiring_stage, report)
    pipeline = expiring_stage.pipeline
    return unless pipeline&.active?

    paid_stage = pipeline.stages.active.find_by(code: 'od_exec_paid')
    return unless paid_stage

    cutoff_date = reference_date + EXPIRING_WINDOW_DAYS.days
    candidate_deals(paid_stage, cutoff_date).find_each do |deal|
      report[:checked] += 1
      process_deal(deal, expiring_stage, report)
    end
  end

  def candidate_deals(paid_stage, cutoff_date)
    Crm::Deal
      .kept
      .where(account_id: paid_stage.account_id, pipeline_id: paid_stage.pipeline_id, stage_id: paid_stage.id)
      .where('expected_close_on IS NOT NULL AND expected_close_on <= ?', cutoff_date)
      .includes(:company)
  end

  def process_deal(deal, expiring_stage, report)
    end_date = deal.expected_close_on
    return unless end_date

    update_renewal_custom_attributes!(deal)
    Crm::Deals::TransitionService.new(
      account: deal.account,
      deal: deal,
      params: { stage_id: expiring_stage.id, lock_version: deal.lock_version }
    ).perform
    report[:transitioned] << deal.id

    task = ensure_renewal_task!(deal, end_date)
    report[:tasks_created] << task.id if task
  end

  def update_renewal_custom_attributes!(deal)
    attrs = (deal.custom_attributes || {}).dup
    return if attrs['od_renewal_state'] == 'expires_soon'

    attrs['od_renewal_state'] = 'expires_soon'
    deal.update!(custom_attributes: attrs)
  end

  def ensure_renewal_task!(deal, end_date)
    end_str = end_date.iso8601
    idem_key = "od_contract_renewal:#{deal.id}:#{end_str}"
    return nil if Crm::Task.exists?(account_id: deal.account_id, idempotency_key: idem_key)

    todo_status = resolve_todo_status(deal.account_id)
    return nil unless todo_status

    Crm::Task.create!(renewal_task_attributes(deal, end_date, end_str, idem_key, todo_status))
  end

  def resolve_todo_status(account_id)
    Crm::TaskStatus.find_by(account_id: account_id, code: 'todo') ||
      Crm::TaskStatus.where(account_id: account_id, category: 'open').order(:position, :id).first
  end

  def resolve_task_type(account_id)
    Crm::TaskType.find_by(account_id: account_id, code: 'task') ||
      Crm::TaskType.where(account_id: account_id).order(:position, :id).first
  end

  def renewal_task_attributes(deal, end_date, end_str, idem_key, todo_status)
    {
      account_id: deal.account_id,
      deal_id: deal.id,
      status_id: todo_status.id,
      task_type_id: resolve_task_type(deal.account_id)&.id,
      assignee_id: deal.owner_id,
      creator_id: deal.owner_id || deal.creator_id,
      priority: 'high',
      all_day: true,
      due_on: [end_date - RENEWAL_TASK_LEAD_DAYS.days, reference_date].max,
      idempotency_key: idem_key,
      external_ref: idem_key,
      title: "Продлить договор юр. адреса — #{resolve_company_label(deal)} (до #{end_str})",
      description: build_task_description(deal, end_str)
    }
  end

  def resolve_company_label(deal)
    deal.company&.name.presence ||
      deal.custom_attributes['od_source_company_name'].presence ||
      deal.title
  end

  def build_task_description(deal, end_str)
    ref = deal.custom_attributes['od_contract_reference'].presence || 'без номера'
    "Договор #{ref} истекает #{end_str}. Связаться с клиентом, выставить счёт и подготовить доп. соглашение / новый договор."
  end
end
