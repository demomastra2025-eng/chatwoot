require 'rails_helper'

RSpec.describe AccountWorkspaceReplies do
  let(:account) { create(:account) }
  let!(:inbox) do
    create(:inbox, account: account, greeting_enabled: true, greeting_message: 'Retired value', out_of_office_message: 'Retired offline')
  end

  it 'keeps new company replies off until configured, independently of retired channel columns' do
    expect(inbox.workspace_greeting_enabled?).to be(false)
    expect(inbox.workspace_greeting_message).to eq('')
    expect(inbox.workspace_out_of_office_message).to be_nil
  end

  it 'inherits one greeting in existing and newly created channels without rewriting them' do
    account.update!(workspace_greeting: { enabled: true, message: 'Company greeting', excluded_inbox_ids: [] })
    inbox.reload
    added = create(:inbox, account: account)
    expect(inbox.workspace_greeting_enabled?).to be(true)
    expect(added.workspace_greeting_enabled?).to be(true)
    expect([inbox.workspace_greeting_message, added.workspace_greeting_message]).to eq(['Company greeting'] * 2)
    expect(inbox[:greeting_message]).to eq('Retired value')
    expect(added[:greeting_message]).not_to eq('Company greeting')
  end

  it 'supports explicit channel exclusions without excluding future channels' do
    account.update!(workspace_greeting: { enabled: true, message: 'Hello', excluded_inbox_ids: [inbox.id] })
    expect(inbox.reload.workspace_greeting_enabled?).to be(false)
    expect(create(:inbox, account: account).workspace_greeting_enabled?).to be(true)
  end

  it 'rejects foreign channel exclusions atomically' do
    other = create(:inbox)
    expect(account.update(workspace_greeting: { enabled: true, message: 'Hello', excluded_inbox_ids: [other.id] })).to be(false)
    expect(account.reload.workspace_greeting_config['enabled']).to be(false)
  end

  it 'rejects enabled blank replies and overlong messages' do
    expect(account.update(workspace_greeting: { enabled: true, message: ' ', excluded_inbox_ids: [] })).to be(false)
    expect(account.update(workspace_out_of_office: { enabled: true, message: '' })).to be(false)
    expect(account.update(workspace_out_of_office: { enabled: true, message: 'x' * (Limits::OUT_OF_OFFICE_MESSAGE_MAX_LENGTH + 1) })).to be(false)
  end

  it 'disables the common offline message without deleting its text' do
    account.update!(workspace_out_of_office: { enabled: true, message: 'Company offline' })
    expect(inbox.reload.workspace_out_of_office_message).to eq('Company offline')
    account.update!(workspace_out_of_office: { enabled: false, message: 'Company offline' })
    expect(inbox.reload.workspace_out_of_office_message).to be_nil
    expect(account.workspace_out_of_office_config['message']).to eq('Company offline')
  end

  it 'returns validation errors for malformed config rather than raising' do
    expect(account.update(workspace_greeting: 'invalid')).to be(false)
    expect(account.update(workspace_out_of_office: [])).to be(false)
  end

  it 'keeps company settings editable after an excluded channel is deleted' do
    account.update!(workspace_greeting: { enabled: true, message: 'Hello', excluded_inbox_ids: [inbox.id] })
    inbox.destroy!
    expect(account.update(workspace_timezone: 'UTC')).to be(true)
  end

  it 'uses the company timezone while preserving the retired raw column for rollback' do
    inbox.update!(timezone: 'America/New_York')
    expect(inbox.reload.timezone).to eq('Asia/Almaty')
    account.update!(workspace_timezone: 'UTC')
    expect(inbox.reload.timezone).to eq('UTC')
    expect(inbox[:timezone]).to eq('America/New_York')
  end
end
