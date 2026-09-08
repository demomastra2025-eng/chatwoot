require 'rails_helper'

RSpec.describe Crm::StageVisits::Tracker do
  let(:deal) { create(:crm_deal) }
  let(:target_stage) { create(:crm_stage, account: deal.account, pipeline: deal.pipeline) }

  it 'closes the previous visit and opens a correlated stage snapshot' do
    correlation_id = SecureRandom.uuid
    previous_visit = described_class.ensure_initial!(deal: deal, correlation_id: correlation_id)
    transitioned_at = 1.minute.from_now
    from_stage_id = deal.stage_id
    deal.update!(stage: target_stage)

    described_class.transition!(
      deal: deal,
      from_stage_id: from_stage_id,
      correlation_id: correlation_id,
      occurred_at: transitioned_at
    )

    expect(previous_visit.reload.exited_at).to be_within(0.000001).of(transitioned_at)
    active_visit = deal.stage_visits.active.first!
    expect(active_visit).to have_attributes(
      stage_id: target_stage.id,
      stage_name: target_stage.name,
      pipeline_name: deal.pipeline.name,
      correlation_id: correlation_id,
      estimated: false
    )
  end
end
