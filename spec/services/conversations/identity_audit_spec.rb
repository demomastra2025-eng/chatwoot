require 'rails_helper'

RSpec.describe Conversations::IdentityAudit do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_sms, account: account) }
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  it 'reports duplicate non-email identities and their dependency counts without mutating records' do
    older = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                                  last_activity_at: 2.days.ago)
    canonical = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                                      last_activity_at: 1.day.ago)
    create(:message, conversation: older, account: account, inbox: inbox)
    older.update!(last_activity_at: 2.days.ago)

    report = described_class.new(account_id: account.id).perform
    group = report[:conflict_groups].sole

    expect(report).to include(read_only: true, identity: 'account_id:inbox_id:contact_id:primary', truncated: false)
    expect(group).to include(
      account_id: account.id,
      inbox_id: inbox.id,
      contact_id: contact.id,
      conversations_count: 2,
      canonical_candidate_id: canonical.id
    )
    expect(group[:conversations].index_by { |item| item[:id] }.dig(older.id, :messages_count)).to eq(1)
    expect(Conversation.where(id: [older.id, canonical.id]).pluck(:identity_key)).to eq([nil, nil])
  end
end
