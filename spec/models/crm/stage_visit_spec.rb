require 'rails_helper'

RSpec.describe Crm::StageVisit do
  let(:deal) { create(:crm_deal) }

  it 'allows only one active visit per deal' do
    create(:crm_stage_visit, deal: deal)

    expect { create(:crm_stage_visit, deal: deal) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'rejects an interval that exits before entry' do
    visit = build(:crm_stage_visit, deal: deal, entered_at: Time.current, exited_at: 1.minute.ago)

    expect(visit).not_to be_valid
    expect(visit.errors[:exited_at]).to include('must not be before entered_at')
  end

  it 'allows one close but rejects later mutation or deletion' do
    visit = create(:crm_stage_visit, deal: deal)
    visit.update!(exited_at: Time.current)

    expect { visit.update!(stage_name: 'Rewritten') }.to raise_error(ActiveRecord::RecordNotSaved)
    expect(visit.destroy).to be false
    expect(visit.reload).to be_persisted
  end

  it 'rejects terminal attribution references outside the visit account' do
    foreign_account = create(:account)
    visit = build(
      :crm_stage_visit,
      deal: deal,
      stage_outcome: 'won',
      terminal_attribution_version: 1,
      owner_id_at_terminal: create(:user, account: foreign_account).id,
      team_id_at_terminal: create(:team, account: foreign_account).id
    )

    expect(visit).not_to be_valid
    expect(visit.errors[:owner_id_at_terminal]).to include('must belong to the account')
    expect(visit.errors[:team_id_at_terminal]).to include('must belong to the account')
  end

  it 'requires a capture marker for snapshot ids and a terminal outcome for captured nil' do
    owner = create(:user, account: deal.account)
    missing_marker = build(:crm_stage_visit, deal: deal, owner_id_at_terminal: owner.id)
    open_capture = build(:crm_stage_visit, deal: deal, terminal_attribution_version: 1)

    expect(missing_marker).not_to be_valid
    expect(missing_marker.errors[:terminal_attribution_version]).to include('is required with terminal attribution')
    expect(open_capture).not_to be_valid
    expect(open_capture.errors[:terminal_attribution_version]).to include('is only valid for terminal visits')
  end

  it 'accepts an old-writer terminal insert without attribution and classifies it as unknown' do
    won_stage = create(:crm_stage, account: deal.account, pipeline: deal.pipeline, outcome: 'won')
    legacy_deal = create(:crm_deal, account: deal.account, pipeline: deal.pipeline, stage: won_stage)
    occurred_at = Time.current

    legacy_attributes = {
      account_id: legacy_deal.account_id,
      deal_id: legacy_deal.id,
      pipeline_id: legacy_deal.pipeline_id,
      stage_id: legacy_deal.stage_id,
      entered_at: occurred_at,
      estimated: false,
      reliable_since: occurred_at,
      pipeline_name: legacy_deal.pipeline.name,
      stage_name: won_stage.name,
      stage_outcome: 'won',
      correlation_id: SecureRandom.uuid,
      created_at: occurred_at,
      updated_at: occurred_at
    }
    result = described_class.insert_all!([legacy_attributes]) # rubocop:disable Rails/SkipsModelValidations -- simulates old code

    legacy_visit = described_class.find(result.rows.sole.sole)
    expect(legacy_visit).to have_attributes(
      terminal_attribution_version: nil,
      owner_id_at_terminal: nil,
      team_id_at_terminal: nil
    )
  end
end
