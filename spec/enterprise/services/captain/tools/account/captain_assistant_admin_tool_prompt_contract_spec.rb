require 'rails_helper'

RSpec.describe Captain::Tools::Account::CaptainAssistantAdminTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account, description: 'Private instructions') }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:platform) { create(:super_admin).tap { |user| create(:account_user, account: account, user: user, role: :administrator) } }

  before do
    allow(Captain::Tools::ToolConfirmationGate).to receive(:new).and_return(instance_double(Captain::Tools::ToolConfirmationGate, call: nil))
  end

  it 'hides instructions in both list and get tools for a clinic administrator' do
    tools = [Captain::Tools::Account::ListCaptainAssistantsService, Captain::Tools::Account::GetCaptainAssistantService]
    tools.each do |tool|
      service = tool.new(assistant, user: admin)
      result = tool == tools.first ? service.execute : service.execute(assistant_id: assistant.id)
      expect(result).not_to include('Private instructions', '"description"')
    end
  end

  it 'rejects a prompt update without exposing the previous prompt or mutating the name' do
    service = Captain::Tools::Account::UpdateCaptainAssistantService.new(assistant, user: admin)
    result = JSON.parse(service.execute(assistant_id: assistant.id, description: 'Client instruction', name: 'Must not save'))
    expect(result).to eq('error' => 'platform_managed_prompt', 'fields' => ['description'])
    expect(assistant.reload.description).to eq('Private instructions')
    expect(assistant.name).not_to eq('Must not save')
  end

  it 'rejects ignored config through tools with a machine-readable result' do
    service = Captain::Tools::Account::UpdateCaptainAssistantService.new(assistant, user: admin)
    result = JSON.parse(service.execute(assistant_id: assistant.id, config_json: { feature_memory: true }.to_json))
    expect(result).to eq('error' => 'unsupported_assistant_settings', 'fields' => ['config.feature_memory'])
  end

  it 'preserves platform read/write tools and ordinary business metadata edits' do
    service = Captain::Tools::Account::UpdateCaptainAssistantService.new(assistant, user: platform)
    payload = JSON.parse(service.execute(assistant_id: assistant.id, description: 'Updated by platform'))
    expect(payload.dig('assistant', 'description')).to eq('Updated by platform')
    expect(payload.dig('previous_assistant', 'description')).to eq('Private instructions')

    result = JSON.parse(Captain::Tools::Account::UpdateCaptainAssistantService.new(assistant, user: admin)
      .execute(assistant_id: assistant.id, name: 'Business edit'))
    expect(result.dig('assistant', 'name')).to eq('Business edit')
    expect(JSON.generate(result)).not_to include('Updated by platform', '"description"')
  end
end
