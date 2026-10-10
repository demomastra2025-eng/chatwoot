class Crm::Appointments::AutomationService
  def initialize(deal:, now: Time.current)
    @deal = deal
    @now = now
  end

  def perform
    deal.with_lock { Crm::Appointments::DeliveryPolicy.with(deal) { evaluate_current_state! } }
    deal
  end

  private

  attr_reader :deal, :now

  def evaluate_current_state!
    config = Crm::Appointments::Configuration.for(deal.pipeline)
    return clear_due_check! unless enabled?(config)

    facts = Crm::Appointments::Facts.new(deal: deal, now: now)
    state = deal.appointment_automation_state.to_h
    fingerprint = facts.fingerprint
    next_check = facts.next_check_at
    return save_check!(state, next_check) if state['manual_fingerprint'] == fingerprint || state['evaluated_fingerprint'] == fingerprint

    rule = config['rules'].find do |candidate|
      stage = deal.pipeline.stages.active.find_by(id: candidate['stage_id'])
      stage && facts.rule_matches?(candidate) && (!stage.outcome_won? || facts.success?)
    end
    transition!(rule, fingerprint) if rule && rule['stage_id'].to_i != deal.stage_id
    state = deal.appointment_automation_state.to_h.except('last_error').merge('evaluated_fingerprint' => fingerprint, 'evaluated_at' => now.iso8601(6))
    save_check!(state, deal.closed? ? nil : next_check)
  rescue Crm::Error => e
    state = deal.appointment_automation_state.to_h.merge('last_error' => e.code, 'evaluated_at' => now.iso8601(6))
    save_check!(state, 1.hour.from_now)
    Rails.logger.warn("CRM appointment stage skipped: account_id=#{deal.account_id} deal_id=#{deal.id} code=#{e.code}")
  end

  def enabled?(config)
    config['enabled'] && deal.account.feature_enabled?('crm_deals') && deal.pipeline.active? && !deal.closed? &&
      deal.archived_at.blank? && deal.stage.outcome_open? && deal.appointment_automation_state.to_h['paused_at'].blank?
  end

  def clear_due_check!
    return if deal.appointment_automation_next_check_at.nil?

    deal.update!(appointment_automation_next_check_at: nil)
  end

  def save_check!(state, next_check)
    return if deal.appointment_automation_state == state && deal.appointment_automation_next_check_at == next_check

    deal.update!(appointment_automation_state: state, appointment_automation_next_check_at: next_check)
  end

  def transition!(rule, fingerprint)
    Crm::Deals::StageCommandService.new(
      account: deal.account, deal: deal, actor: nil,
      params: {
        stage_id: rule['stage_id'], lock_version: deal.lock_version,
        closing_reasons: rule['closing_reasons'], transition_reason: rule['transition_reason'],
        idempotency_key: "appointment_stage:#{fingerprint}:#{deal.lock_version}:#{rule['stage_id']}", appointment_automation: true
      }
    ).perform
  end
end
