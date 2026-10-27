require 'rails_helper'
require Rails.root.join('db/migrate/20261011110000_add_captain_channel_membership')

# The migration has run everywhere. Its data comes from tables the application no longer has models for, so the spec writes and reads
# them directly.
RSpec.describe AddCaptainChannelMembership, type: :model do
  let(:handoffs) { Class.new(ApplicationRecord) { self.table_name = 'captain_agent_handoffs' } }
  let(:channels) { Class.new(ApplicationRecord) { self.table_name = 'captain_agent_channels' } }

  def link(account, source, target)
    handoffs.create!(account_id: account.id, source_assistant_id: source.id, target_assistant_id: target.id)
  end

  it 'preserves transitive graph reachability and can be rerun' do
    account = create(:account)
    inbox = create(:inbox, account: account)
    entry = create(:captain_assistant, account: account)
    middle = create(:captain_assistant, account: account)
    leaf = create(:captain_assistant, account: account)
    excluded = create(:captain_assistant, account: account)
    # The text channel of that time named its entry agent.
    CaptainInbox.new(inbox: inbox, captain_assistant_id: entry.id).save!(validate: false)
    link(account, entry, middle)
    link(account, middle, leaf)
    link(account, middle, excluded)
    excluded.update!(active: false)
    expected_ids = [entry.id, middle.id, leaf.id].sort

    described_class.new.backfill_membership!
    described_class.new.backfill_membership!

    expect(channels.where(inbox_id: inbox.id).pluck(:assistant_id).sort).to eq(expected_ids)
    expect(channels.where(inbox_id: inbox.id).count).to eq(expected_ids.size)
    expect(handoffs.where(source_assistant_id: entry.id).pluck(:target_assistant_id)).to eq([middle.id])
  end
end
