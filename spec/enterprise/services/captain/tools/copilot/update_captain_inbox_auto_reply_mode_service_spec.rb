require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdateCaptainInboxAutoReplyModeService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account, name: 'Support AI') }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  it 'updates an account Captain inbox auto-reply mode' do
    inbox = create(:inbox, account: account, name: 'Support')
    captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant, auto_reply_mode: CaptainInbox::AUTO_REPLY_ALWAYS)

    payload = JSON.parse(service.execute(inbox_id: inbox.id, auto_reply_mode: CaptainInbox::AUTO_REPLY_NEVER))

    expect(payload['action']).to eq('update_captain_inbox_auto_reply_mode')
    expect(payload['inbox']).to include('id' => inbox.id, 'name' => 'Support')
    expect(payload['captain']).to include(
      'assistant_id' => assistant.id,
      'assistant_name' => 'Support AI',
      'auto_reply_mode' => CaptainInbox::AUTO_REPLY_NEVER,
      'auto_reply_allowed_now' => false
    )
    expect(captain_inbox.reload.auto_reply_mode).to eq(CaptainInbox::AUTO_REPLY_NEVER)
  end

  it 'allows account admins to update a same-account inbox connected to another Captain assistant' do
    other_assistant = create(:captain_assistant, account: account, name: 'Sales AI')
    inbox = create(:inbox, account: account, name: 'Sales')
    captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: other_assistant, auto_reply_mode: CaptainInbox::AUTO_REPLY_ALWAYS)

    payload = JSON.parse(service.execute(inbox_id: inbox.id, auto_reply_mode: CaptainInbox::AUTO_REPLY_WORKING_HOURS))

    expect(payload.dig('captain', 'assistant_id')).to eq(other_assistant.id)
    expect(payload.dig('captain', 'assistant_name')).to eq('Sales AI')
    expect(captain_inbox.reload.auto_reply_mode).to eq(CaptainInbox::AUTO_REPLY_WORKING_HOURS)
  end

  it 'rejects inboxes outside the assistant account' do
    other_inbox = create(:inbox, account: create(:account))
    create(:captain_inbox, inbox: other_inbox, captain_assistant: create(:captain_assistant, account: other_inbox.account))

    result = service.execute(inbox_id: other_inbox.id, auto_reply_mode: CaptainInbox::AUTO_REPLY_NEVER)

    expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
  end

  it 'rejects invalid auto-reply modes' do
    inbox = create(:inbox, account: account)
    captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant, auto_reply_mode: CaptainInbox::AUTO_REPLY_ALWAYS)

    result = service.execute(inbox_id: inbox.id, auto_reply_mode: 'invalid')

    expect(result).to include('auto_reply_mode must be one of')
    expect(captain_inbox.reload.auto_reply_mode).to eq(CaptainInbox::AUTO_REPLY_ALWAYS)
  end

  it 'rejects direct non-admin execution as defense in depth' do
    agent = create(:user, account: account)
    service = described_class.new(assistant, user: agent)
    inbox = create(:inbox, account: account)
    captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant, auto_reply_mode: CaptainInbox::AUTO_REPLY_ALWAYS)

    result = service.execute(inbox_id: inbox.id, auto_reply_mode: CaptainInbox::AUTO_REPLY_NEVER)

    expect(result).to include('Account administrator permission is required')
    expect(captain_inbox.reload.auto_reply_mode).to eq(CaptainInbox::AUTO_REPLY_ALWAYS)
  end

  it 'does not mutate until the backend confirmation gate permits execution' do
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
    inbox = create(:inbox, account: account)
    captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: assistant, auto_reply_mode: CaptainInbox::AUTO_REPLY_ALWAYS)

    payload = JSON.parse(service.execute(inbox_id: inbox.id, auto_reply_mode: CaptainInbox::AUTO_REPLY_NEVER))

    expect(payload['message']).to include('Operator confirmation is required')
    expect(captain_inbox.reload.auto_reply_mode).to eq(CaptainInbox::AUTO_REPLY_ALWAYS)
  end

  it 'is active only for account administrators' do
    agent = create(:user, account: account)

    expect(service).to be_active
    expect(described_class.new(assistant, user: agent)).not_to be_active
  end
end
