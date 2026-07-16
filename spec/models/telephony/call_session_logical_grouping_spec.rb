require 'rails_helper'

RSpec.describe Telephony::CallSession::LogicalGrouping do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:number_binding) { create(:telephony_number_binding, account: account, inbox: inbox) }
  let(:started_at) { Time.zone.parse('2026-07-16 09:34:41 UTC') }

  def create_session(call_ref:, logical_key:, group_ref:, offset: 0)
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: inbox,
      number_binding: number_binding,
      provider: 'sipuni',
      direction: 'inbound',
      status: 'ringing',
      external_call_ref: call_ref,
      started_at: started_at + offset.seconds,
      created_at: started_at + offset.seconds,
      metadata: {
        'metadata' => {
          'logical_call_key' => logical_key,
          'call_group_key' => logical_key,
          'logical_call_group_ref' => group_ref
        }
      }
    )
  end

  it 'resolves a transitive fan-out group even when a late branch has a different logical key' do
    root = create_session(call_ref: 'root-202', logical_key: 'logical-root', group_ref: 'root-202')
    middle = create_session(call_ref: 'branch-204', logical_key: 'logical-root', group_ref: 'root-202', offset: 1)
    leaf = create_session(call_ref: 'branch-206', logical_key: 'logical-late', group_ref: 'branch-204', offset: 2)
    unrelated = create_session(call_ref: 'other-call', logical_key: 'logical-other', group_ref: 'other-call', offset: 3)

    expect(leaf.logical_group_sessions.map(&:id)).to contain_exactly(root.id, middle.id, leaf.id)
    expect(leaf.canonical_logical_call_session.id).to eq(root.id)
    expect(leaf.canonical_logical_call_key).to eq('logical-root')
    expect(leaf.logical_group_sessions.map(&:id)).not_to include(unrelated.id)
  end
end
