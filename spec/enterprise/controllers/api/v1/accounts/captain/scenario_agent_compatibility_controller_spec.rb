require 'rails_helper'

RSpec.describe 'Captain legacy scenario compatibility', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:parent) { create(:captain_assistant, account: account, description: 'Parent main instruction') }
  let(:scenario) { create(:captain_scenario, assistant: parent, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/assistants/#{parent.id}/scenarios/#{scenario.id}" }
  let(:headers) { admin.create_new_auth_token }

  def mapped_agent
    Captain::Assistant.find_by!(legacy_scenario_id: scenario.id)
  end

  before { Captain::LegacyScenarioConversionService.new.convert!(scenario.id) }

  it 'adapts a legacy scenario save to its independently configured agent' do
    patch path, headers: headers, as: :json, params: {
      scenario: { title: 'Billing', description: 'Use for billing', instruction: 'Own billing instruction', enabled: false }
    }

    expect(response).to have_http_status(:success)
    expect(mapped_agent).to have_attributes(
      name: 'Billing', routing_description: 'Use for billing', description: 'Own billing instruction', active: false
    )
    expect(JSON.parse(response.body)['standalone_agent_id']).to eq(mapped_agent.id)
  end

  it 'shows current agent settings after the independent agent is edited' do
    mapped_agent.update!(name: 'Edited agent', description: 'Edited own prompt', active: false)

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:success)
    expect(JSON.parse(response.body)).to include('title' => 'Edited agent', 'instruction' => 'Edited own prompt', 'enabled' => false)
  end

  it 'does not overwrite independent prompt or name edits in an enabled-only legacy patch' do
    mapped_agent.update!(name: 'Independent name', description: 'Independent own instruction')

    patch path, headers: headers, as: :json, params: { scenario: { enabled: false } }

    expect(response).to have_http_status(:success)
    expect(mapped_agent).to have_attributes(name: 'Independent name', description: 'Independent own instruction', active: false)
  end

  it 'updates the preserved own tool list through a legacy tools patch' do
    patch path, headers: headers, as: :json, params: { scenario: { tools: ['add_private_note'] } }

    expect(response).to have_http_status(:success)
    expect(mapped_agent.config.dig('legacy_scenario_migration', 'explicit_tool_ids')).to eq(['add_private_note'])
    expect(mapped_agent.config.dig('tool_access', 'agent', 'tool_ids')).to include('add_private_note')

    patch path, headers: headers, as: :json, params: { scenario: { tools: [] } }

    expect(response).to have_http_status(:success)
    expect(mapped_agent.config.dig('legacy_scenario_migration', 'explicit_tool_ids')).to be_empty
    expect(mapped_agent.config.dig('tool_access', 'agent', 'tool_ids')).not_to include('add_private_note')
  end

  it 'deactivates the mapped agent and retains the scenario mapping on legacy delete' do
    agent_id = mapped_agent.id
    delete path, headers: headers, as: :json

    expect(response).to have_http_status(:no_content)
    expect(Captain::Scenario.find(scenario.id)).not_to be_enabled
    expect(Captain::Assistant.find(agent_id)).to have_attributes(active: false, legacy_scenario_id: scenario.id)
  end

  it 'rolls back both sides of a legacy edit when the independent agent validation fails' do
    original_title = scenario.title
    patch path, headers: headers, as: :json, params: { scenario: { title: 'Uncommitted title', instruction: '' } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(scenario.reload.title).to eq(original_title)
    expect(mapped_agent.name).to eq(original_title)
  end
end
