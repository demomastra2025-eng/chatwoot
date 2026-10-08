require 'rails_helper'

RSpec.describe 'inbox member factory' do
  it 'reuses an automatically created membership without inserting another row' do
    user = create(:user, account: create(:account))
    inbox = create(:inbox, account: user.accounts.sole)
    existing_member = inbox.inbox_members.find_by!(user: user)
    member = nil

    expect { member = create(:inbox_member, inbox: inbox, user: user) }.not_to change(InboxMember, :count)

    expect(member).to be_persisted
    expect(member.id).to eq(existing_member.id)
  end

  it 'saves a missing membership through the native create callback' do
    inbox = create(:inbox)
    user = create(:user)
    round_robin = instance_double(AutoAssignment::InboxRoundRobinService, add_agent_to_queue: nil)
    allow(AutoAssignment::InboxRoundRobinService).to receive(:new).with(inbox: inbox).and_return(round_robin)

    member = create(:inbox_member, inbox: inbox, user: user)

    expect(member).to be_persisted
    expect(round_robin).to have_received(:add_agent_to_queue).with(user.id).once
  end

  it 'rejects extra attributes rather than discarding them while reusing a membership' do
    user = create(:user, account: create(:account))
    inbox = create(:inbox, account: user.accounts.sole)
    existing_member = inbox.inbox_members.find_by!(user: user)
    original_created_at = existing_member.created_at

    expect do
      create(:inbox_member, inbox: inbox, user: user, created_at: original_created_at - 1.day)
    end.to raise_error(ArgumentError, /overridden attributes: created_at/)

    expect(existing_member.reload.created_at).to eq(original_created_at)
  end
end
