require 'rails_helper'

RSpec.describe 'Captain standalone agent settings', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:target) { create(:captain_assistant, account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}" }
  let(:headers) { admin.create_new_auth_token }

  it 'saves prompt, activity, routing description and graph together and returns their public shape' do
    patch path, headers: headers, as: :json, params: {
      assistant: { description: 'Own agent prompt', routing_description: 'Use for billing', active: true, handoff_agent_ids: [target.id] }
    }

    expect(response).to have_http_status(:success)
    expect(JSON.parse(response.body)).to include(
      'description' => 'Own agent prompt', 'routing_description' => 'Use for billing', 'active' => true, 'handoff_agent_ids' => [target.id]
    )
  end

  it 'rolls back the complete settings save for a cross workspace target' do
    assistant.update!(handoff_agent_ids: [target.id])
    original = assistant.attributes.slice('name', 'description', 'active')
    foreign_target = create(:captain_assistant)

    patch path, headers: headers, as: :json, params: {
      assistant: { name: 'Uncommitted name', description: 'Uncommitted prompt', active: false, handoff_agent_ids: [foreign_target.id] }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(assistant.reload.attributes.slice('name', 'description', 'active')).to eq(original)
    expect(assistant.handoff_agent_ids).to eq([target.id])
  end

  it 'rejects newly selected inactive and internal targets' do
    target.update!(active: false)
    patch path, headers: headers, as: :json, params: { assistant: { handoff_agent_ids: [target.id] } }
    expect(response).to have_http_status(:unprocessable_content)

    target.update!(active: true, usage_mode: 'internal_assistant')
    patch path, headers: headers, as: :json, params: { assistant: { handoff_agent_ids: [target.id] } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(assistant.reload.handoff_agent_ids).to be_empty
  end

  it 'rolls back the prompt and existing routes if graph persistence fails after saving the agent row' do
    assistant.update!(handoff_agent_ids: [target.id])
    new_target = create(:captain_assistant, account: account)
    invalid_route = Captain::AgentHandoff.new
    invalid_route.errors.add(:target_assistant, 'became unavailable')
    allow_any_instance_of(Captain::AgentHandoff).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(invalid_route))

    patch path, headers: headers, as: :json, params: {
      assistant: { description: 'Uncommitted prompt', handoff_agent_ids: [new_target.id] }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(assistant.reload.description).to eq('Test description')
    expect(assistant.handoff_agent_ids).to eq([target.id])
  end
end
