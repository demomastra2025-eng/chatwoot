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

  it 'captures immutable owner and team identity when entering a terminal stage' do
    owner = create(:user, account: deal.account)
    team = create(:team, account: deal.account)
    terminal_stage = create(:crm_stage, account: deal.account, pipeline: deal.pipeline, outcome: 'won')
    described_class.ensure_initial!(deal: deal, correlation_id: SecureRandom.uuid)
    from_stage_id = deal.stage_id
    deal.update!(stage: terminal_stage, owner: owner, team: team)

    described_class.transition!(deal: deal, from_stage_id: from_stage_id, correlation_id: SecureRandom.uuid)

    visit = deal.stage_visits.active.first!
    expect(visit).to have_attributes(
      owner_id_at_terminal: owner.id,
      team_id_at_terminal: team.id,
      terminal_attribution_version: 1
    )

    deal.update!(owner: nil, team: nil)
    expect(visit.reload).to have_attributes(owner_id_at_terminal: owner.id, team_id_at_terminal: team.id)
  end

  it 'captures known unassigned independently from legacy or estimated unknown attribution' do
    terminal_stage = create(:crm_stage, account: deal.account, pipeline: deal.pipeline, outcome: 'lost')
    deal.update!(stage: terminal_stage, owner: nil, team: nil)

    captured = described_class.ensure_initial!(deal: deal, correlation_id: SecureRandom.uuid)
    legacy_deal = create(:crm_deal)
    legacy_terminal_stage = create(:crm_stage, account: legacy_deal.account, pipeline: legacy_deal.pipeline, outcome: 'won')
    legacy = create(
      :crm_stage_visit,
      deal: legacy_deal,
      stage: legacy_terminal_stage,
      pipeline: legacy_terminal_stage.pipeline,
      stage_outcome: 'won',
      terminal_attribution_version: nil
    )
    estimated = described_class.ensure_initial!(
      deal: create(:crm_deal, stage: terminal_stage, pipeline: terminal_stage.pipeline, account: terminal_stage.account),
      correlation_id: SecureRandom.uuid,
      estimated: true
    )

    expect(captured).to have_attributes(
      owner_id_at_terminal: nil,
      team_id_at_terminal: nil,
      terminal_attribution_version: 1
    )
    expect(legacy.terminal_attribution_version).to be_nil
    expect(estimated.terminal_attribution_version).to be_nil
  end

  it 'preserves snapshot ids after current assignment and membership records are removed' do
    owner = create(:user, account: deal.account)
    team = create(:team, account: deal.account)
    membership = create(:team_member, team: team, user: owner)
    terminal_stage = create(:crm_stage, account: deal.account, pipeline: deal.pipeline, outcome: 'won')
    deal.update!(stage: terminal_stage, owner: owner, team: team)
    visit = described_class.ensure_initial!(deal: deal, correlation_id: SecureRandom.uuid)

    deal.update!(owner: nil, team: nil)
    membership.destroy!
    team.destroy!
    deal.account.account_users.find_by!(user: owner).destroy!
    open_stage = create(:crm_stage, account: deal.account, pipeline: deal.pipeline)
    from_stage_id = deal.stage_id
    deal.update!(stage: open_stage)
    described_class.transition!(deal: deal, from_stage_id: from_stage_id, correlation_id: SecureRandom.uuid)

    expect(visit.reload).to have_attributes(owner_id_at_terminal: owner.id, team_id_at_terminal: team.id)
    expect(visit.exited_at).to be_present
    expect(deal.stage_visits.active.sole.stage_id).to eq(open_stage.id)

    lost_stage = create(:crm_stage, account: deal.account, pipeline: deal.pipeline, outcome: 'lost')
    from_stage_id = deal.stage_id
    deal.update!(stage: lost_stage)
    described_class.transition!(deal: deal, from_stage_id: from_stage_id, correlation_id: SecureRandom.uuid)

    expect(deal.stage_visits.active.sole).to have_attributes(
      stage_id: lost_stage.id,
      owner_id_at_terminal: nil,
      team_id_at_terminal: nil,
      terminal_attribution_version: 1
    )
  end
end
