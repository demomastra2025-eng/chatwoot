require 'rails_helper'

RSpec.describe 'Captain workspace agents', type: :model do
  let(:account) { create(:account) }
  let(:first_agent) { create(:captain_assistant, account: account) }
  let(:second_agent) { create(:captain_assistant, account: account) }

  it 'has no default or main agent of the workspace' do
    expect(account).not_to respond_to(:captain_default_assistant_id)
    expect(account).not_to respond_to(:captain_default_assistant_id=)
    expect(Captain::Assistant.new).not_to respond_to(:main_in_inbox_ids)
  end

  it 'lets every agent be switched off, in any order, while a channel is switched on' do
    create(:captain_inbox, inbox: create(:inbox, account: account), ai_enabled: true)
    [first_agent, second_agent]

    expect(second_agent.update(active: false)).to be(true)
    expect(first_agent.update(active: false)).to be(true)
    expect(account.captain_assistants.entry_eligible).to be_empty
  end

  it 'lets any agent be deleted while a channel is switched on' do
    row = create(:captain_inbox, inbox: create(:inbox, account: account), ai_enabled: true)

    expect { first_agent.destroy! }.not_to raise_error
    expect(row.reload).to be_ai_enabled
  end

  it 'creates no channel row for a new text inbox' do
    first_agent

    expect(create(:inbox, account: account).captain_inbox).to be_nil
  end
end
