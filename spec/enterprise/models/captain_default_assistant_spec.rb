require 'rails_helper'

RSpec.describe 'Captain workspace default agent', type: :model do
  let(:account) { create(:account) }
  let(:agent) { create(:captain_assistant, account: account) }

  it 'accepts an active external agent in the workspace' do
    account.update!(captain_default_assistant_id: agent.id)

    expect(account.reload.captain_default_assistant_id).to eq(agent.id)
  end

  it 'rejects an inactive, internal or foreign default agent' do
    foreign = create(:captain_assistant)
    account.captain_default_assistant_id = foreign.id
    expect(account).not_to be_valid

    agent.update!(active: false)
    account.captain_default_assistant_id = agent.id
    expect(account).not_to be_valid

    agent.update!(active: true, usage_mode: 'internal_assistant')
    expect(account).not_to be_valid
  end

  it 'prevents disabling the selected default agent' do
    account.update!(captain_default_assistant_id: agent.id)

    expect { agent.update!(active: false) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(agent.reload).to be_active
  end
end
