# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain account settings write isolation' do # rubocop:disable RSpec/DescribeClass
  let(:account) do
    create(:account,
           workspace_greeting: { 'enabled' => false, 'message' => 'Before', 'excluded_inbox_ids' => [] },
           auto_resolve_message: 'Original unrelated value', audio_transcriptions: false)
  end
  let(:admin) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let!(:inbox) { create(:inbox, account: account, name: 'Original inbox', working_hours_enabled: false) }

  before do
    allow(Captain::Tools::ToolConfirmationGate).to receive(:new)
      .and_return(instance_double(Captain::Tools::ToolConfirmationGate, call: nil))
  end

  def stale_service(klass)
    # Load the actual association before the concurrent write. No replacement of
    # update!, with_lock, or any method inside a writer's lock is performed.
    record = Captain::Assistant.find(assistant.id)
    expect(record.account.workspace_greeting['message']).to eq('Before')
    service = klass.new(record, user: admin)
    fresh = Account.find(account.id)
    fresh.with_lock('FOR NO KEY UPDATE') do
      fresh.update!(
        workspace_greeting: { 'enabled' => false, 'message' => 'Company saved', 'excluded_inbox_ids' => [] },
        auto_resolve_message: 'Concurrent unrelated value'
)
    end
    expect(record.account.workspace_greeting['message']).to eq('Before')
    [service, fresh.settings.slice('workspace_greeting', 'auto_resolve_message', 'audio_transcriptions')]
  end

  def expect_fresh_company_keys(expected)
    expect(account.reload.settings.slice(*expected.keys)).to eq(expected)
  end

  it 'preserves fresh common and unrelated keys when updating working hours through the tool entry point' do
    service, expected = stale_service(Captain::Tools::Account::UpdateInboxWorkingHoursService)
    schedule = AccountWorkspaceWorkingHours::DEFAULT_SCHEDULE.deep_dup
    schedule[1]['open_hour'] = 10
    result = JSON.parse(service.execute(inbox_id: inbox.id, working_hours_json: schedule.to_json))
    expect(result['action']).to eq('update_inbox_working_hours')
    expect_fresh_company_keys(expected)
    expect(account.workspace_working_hours_schedule[1]['open_hour']).to eq(10)
    expect(inbox.reload.working_hours_enabled).to be(false)
  end

  it 'preserves fresh common and unrelated keys when changing the workspace assignment switch through the inbox tool' do
    service, expected = stale_service(Captain::Tools::Account::UpdateInboxSettingsService)
    result = JSON.parse(service.execute(inbox_id: inbox.id, name: 'Updated inbox', enable_auto_assignment: false))
    expect(result['action']).to eq('update_inbox_settings')
    expect_fresh_company_keys(expected)
    expect(account.conversation_auto_assignment_enabled?).to be(false)
    expect(inbox.reload.name).to eq('Updated inbox')
  end

  it 'preserves fresh common and unrelated keys when updating the workspace profile tool' do
    service, expected = stale_service(Captain::Tools::Account::UpdateWorkspaceProfileService)
    result = JSON.parse(service.execute(name: 'Updated company', auto_resolve_after: 30))
    expect(result['action']).to eq('update_workspace_profile')
    expect_fresh_company_keys(expected)
    expect(account.name).to eq('Updated company')
    expect(account.settings['auto_resolve_after']).to eq(30)
  end
end
