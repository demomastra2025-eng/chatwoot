class Crm::StageVisits::Tracker
  class MissingActiveVisit < StandardError; end

  def self.ensure_initial!(deal:, correlation_id:, occurred_at: Time.current, estimated: false)
    deal.stage_visits.active.first || create_visit!(
      deal: deal,
      stage: deal.stage,
      correlation_id: correlation_id,
      occurred_at: occurred_at,
      estimated: estimated
    )
  end

  def self.transition!(deal:, from_stage_id:, correlation_id:, occurred_at: Time.current)
    return ensure_initial!(deal: deal, correlation_id: correlation_id, occurred_at: occurred_at) if from_stage_id.blank?
    return if from_stage_id == deal.stage_id

    active_visit = deal.stage_visits.active.lock.first
    raise MissingActiveVisit, "Deal #{deal.id} has no active stage visit" if active_visit.blank?
    raise MissingActiveVisit, "Deal #{deal.id} active visit does not match stage #{from_stage_id}" if active_visit.stage_id != from_stage_id

    active_visit.update!(exited_at: occurred_at)
    create_visit!(
      deal: deal,
      stage: deal.stage,
      correlation_id: correlation_id,
      occurred_at: occurred_at,
      estimated: false
    )
  end

  def self.create_visit!(deal:, stage:, correlation_id:, occurred_at:, estimated:)
    attributes = {
      account: deal.account,
      deal: deal,
      pipeline: stage.pipeline,
      stage: stage,
      entered_at: occurred_at,
      reliable_since: occurred_at,
      estimated: estimated,
      pipeline_name: stage.pipeline.name,
      stage_name: stage.name,
      stage_outcome: stage.outcome,
      correlation_id: correlation_id
    }
    attributes.merge!(terminal_attribution(deal)) if !estimated && !stage.outcome_open?

    Crm::StageVisit.create!(attributes)
  end
  private_class_method :create_visit!

  def self.terminal_attribution(deal)
    {
      owner_id_at_terminal: deal.owner_id,
      team_id_at_terminal: deal.team_id,
      terminal_attribution_version: Crm::StageVisit::TERMINAL_ATTRIBUTION_VERSION
    }
  end
  private_class_method :terminal_attribution
end
