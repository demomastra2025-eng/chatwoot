require 'rails_helper'

RSpec.describe CaptainInbox do
  include ActiveJob::TestHelper
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  it 'rejects new inactive and internal entry agents' do
    assistant.update!(active: false)
    expect(build(:captain_inbox, inbox: inbox, captain_assistant: assistant)).not_to be_valid
    assistant.update!(active: true, usage_mode: 'internal_assistant')
    expect(build(:captain_inbox, inbox: inbox, captain_assistant: assistant)).not_to be_valid
  end

  it 'rejects entry assignments from another workspace' do
    expect(build(:captain_inbox, inbox: inbox, captain_assistant: create(:captain_assistant))).not_to be_valid
  end

  it 'retains the configured entry when the agent is temporarily deactivated' do
    assignment = create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    assistant.update!(active: false)

    expect(assignment.reload).to be_valid
    expect(assignment.captain_assistant_id).to eq(assistant.id)
  end

  it 'acquires the shared assistant assignment lock on save and destroy' do
    captain_inbox = build(:captain_inbox, inbox: inbox, captain_assistant: assistant)

    expect(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).with(inbox.id).exactly(3).times.and_call_original
    captain_inbox.save!
    captain_inbox.update!(auto_reply_mode: 'working_hours')
    captain_inbox.destroy!
  end

  it 'uses the shared lock when an assistant asynchronously destroys its assignments' do
    captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant)

    expect(Telephony::AiVoice::AssistantAssignmentLock).to receive(:acquire!).with(inbox.id).twice.and_call_original
    perform_enqueued_jobs { assistant.destroy! }

    expect(described_class.where(id: captain_inbox.id)).not_to exist
  end

  it 'rolls back assignment creation when routing policy sync fails' do
    captain_inbox = build(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    allow(captain_inbox).to receive(:sync_voice_routing_policy!).and_raise('sync failed')

    expect do
      described_class.transaction(requires_new: true) { captain_inbox.save! }
    end.to raise_error(RuntimeError, 'sync failed')

    expect(described_class.where(inbox_id: inbox.id)).not_to exist
  end

  it 'rolls back assignment deletion when routing policy cleanup fails' do
    captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    allow(captain_inbox).to receive(:clear_voice_routing_policy).and_raise('cleanup failed')

    expect do
      described_class.transaction(requires_new: true) { captain_inbox.destroy! }
    end.to raise_error(RuntimeError, 'cleanup failed')

    expect(described_class.where(id: captain_inbox.id)).to exist
  end
end
