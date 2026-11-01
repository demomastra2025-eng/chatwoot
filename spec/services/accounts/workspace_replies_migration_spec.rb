require 'rails_helper'

RSpec.describe Accounts::WorkspaceRepliesMigration do
  let(:account) { create(:account) }
  let!(:first) { create(:inbox, account: account, greeting_enabled: true, greeting_message: 'Hello', out_of_office_message: 'Offline') }
  let!(:second) { create(:inbox, account: account, greeting_enabled: false, greeting_message: 'Old draft', out_of_office_message: '') }
  let(:service) { described_class.new(account) }
  let(:choices) do
    {
      'workspace_greeting' => { 'enabled' => true, 'message' => 'Chosen greeting', 'excluded_inbox_ids' => [second.id] },
      'workspace_out_of_office' => { 'enabled' => true, 'message' => 'Chosen offline' }
    }
  end

  before do
    account.update!(settings: account.settings.except('workspace_greeting', 'workspace_out_of_office'))
  end

  it 'inspects without modifying data and adopts only an unambiguous common value' do
    snapshot = service.report
    expect(snapshot[:conflicts]).to be_empty
    expect(account.reload.workspace_greeting).to be_nil
    expect do
      service.apply!(expected_digest: snapshot[:digest])
    end.not_to(change { [first.reload.attributes, second.reload.attributes] })
    expect(account.reload.workspace_greeting_config).to eq('enabled' => true, 'message' => 'Hello', 'excluded_inbox_ids' => [second.id])
    expect(account.workspace_out_of_office_config).to eq('enabled' => true, 'message' => 'Offline')
  end

  it 'keeps an unambiguous paused greeting without enabling it or excluding future channels' do
    first.update!(greeting_enabled: false)
    second.update!(greeting_message: '')
    service.apply!(expected_digest: service.report[:digest])
    expect(account.reload.workspace_greeting_config).to eq('enabled' => false, 'message' => 'Hello', 'excluded_inbox_ids' => [])
  end

  it 'refuses divergent greetings without arbitrarily choosing or overwriting a text' do
    second.update!(greeting_enabled: true, greeting_message: 'Different')
    snapshot = service.report
    expect(snapshot[:conflicts]).to include('workspace_greeting')
    expect { service.apply!(expected_digest: snapshot[:digest]) }.to raise_error(described_class::Conflict)
    expect(account.reload.workspace_greeting).to be_nil
    expect([first.reload[:greeting_message], second.reload[:greeting_message]]).to eq(%w[Hello Different])
  end

  it 'refuses divergent offline texts' do
    second.update!(out_of_office_message: 'Another offline')
    snapshot = service.report
    expect(snapshot[:conflicts]).to include('workspace_out_of_office')
    expect { service.apply!(expected_digest: snapshot[:digest]) }.to raise_error(described_class::Conflict)
    expect(account.reload.workspace_out_of_office).to be_nil
  end

  it 'refuses stale inspection after a legacy field changed' do
    snapshot = service.report
    first.update!(greeting_message: 'Changed during inspection')
    expect { service.apply!(expected_digest: snapshot[:digest]) }.to raise_error(described_class::Conflict, /changed/)
    expect(account.reload.workspace_greeting).to be_nil
  end

  it 'does not overwrite an explicit common message chosen to resolve a conflict' do
    second.update!(greeting_enabled: true, greeting_message: 'Different')
    account.update!(workspace_greeting: { enabled: true, message: 'Explicit choice', excluded_inbox_ids: [] })
    snapshot = service.report
    expect(snapshot[:conflicts]).to be_empty
    service.apply!(expected_digest: snapshot[:digest])
    expect(account.reload.workspace_greeting_message).to eq('Explicit choice')
    expect(service.report[:configs]).to be_empty
  end

  it 'is idempotent and does not create any messages' do
    service.apply!(expected_digest: service.report[:digest])
    expect do
      expect { service.apply!(expected_digest: service.report[:digest]) }.not_to change(Message, :count)
    end.not_to(change { account.reload.updated_at })
  end

  it 'resolves conflicting values before app switch without touching retired columns or sending messages' do
    second.update!(greeting_enabled: true, greeting_message: 'Different', out_of_office_message: 'Another offline')
    snapshot = service.report
    retired = [first.reload.attributes, second.reload.attributes]
    expect(snapshot[:conflicts]).to contain_exactly('workspace_greeting', 'workspace_out_of_office')
    expect { service.apply!(expected_digest: snapshot[:digest], configs: choices) }.not_to change(Message, :count)
    expect(account.reload.workspace_greeting).to eq(choices['workspace_greeting'])
    expect(account.workspace_out_of_office).to eq(choices['workspace_out_of_office'])
    expect([first.reload.attributes, second.reload.attributes]).to eq(retired)
    expect(service.report[:configs]).to be_empty
  end

  it 'requires a fresh inspected digest even for an explicit choice' do
    snapshot = service.report
    first.update!(greeting_message: 'Changed after choice')
    expect { service.apply!(expected_digest: snapshot[:digest], configs: choices) }.to raise_error(described_class::Conflict, /changed/)
    expect(account.reload.workspace_greeting).to be_nil
  end

  it 'rejects unrelated account attributes without partially applying the choices' do
    expect do
      service.apply!(expected_digest: service.report[:digest], configs: choices.merge('name' => 'Unexpected'))
    end.to raise_error(described_class::Conflict, /exactly/)
    expect(account.reload.workspace_greeting).to be_nil
    expect(account.workspace_out_of_office).to be_nil
  end

  it 'rejects malformed or incomplete choices instead of substituting a guessed value' do
    [[], choices.except('workspace_out_of_office')].each do |invalid|
      expect { service.apply!(expected_digest: service.report[:digest], configs: invalid) }.to raise_error(described_class::Conflict)
    end
    expect(account.reload.workspace_greeting).to be_nil
  end

  it 'validates both choices atomically' do
    choices['workspace_out_of_office']['message'] = ''
    expect do
      service.apply!(expected_digest: service.report[:digest], configs: choices)
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(account.reload.workspace_greeting).to be_nil
    expect(account.workspace_out_of_office).to be_nil
  end

  it 'rejects exclusions from another company through the normal model validation' do
    choices['workspace_greeting']['excluded_inbox_ids'] = [create(:inbox).id]
    expect do
      service.apply!(expected_digest: service.report[:digest], configs: choices)
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(account.reload.workspace_greeting).to be_nil
    expect(account.workspace_out_of_office).to be_nil
  end
end
