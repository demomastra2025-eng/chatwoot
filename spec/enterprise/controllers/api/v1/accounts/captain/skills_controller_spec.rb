require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Skills', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/:account_id/captain/skills' do
    it 'returns only workspace skills for the current account' do
      skill = create(:captain_skill, account: account, name: 'Sales Follow Up', description: 'Close next steps')
      create(:captain_skill, account: create(:account), name: 'Other Account Skill')

      get "/api/v1/accounts/#{account.id}/captain/skills",
          params: { search: 'sales' },
          headers: agent.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response[:payload]).to contain_exactly(
        include(
          id: skill.slug,
          name: 'Sales Follow Up',
          editable: true,
          source_type: 'workspace',
          workspace_skill_id: skill.id
        )
      )
      expect(json_response[:meta]).to eq({ total_count: 1, page: 1 })
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/skills' do
    let(:valid_params) do
      {
        skill: {
          name: 'Discovery Script',
          description: 'Qualify leads consistently',
          content: 'Ask for budget, authority, need, and timeline.',
          group_name: 'Sales'
        }
      }
    end

    it 'does not allow a regular agent to create workspace skills' do
      post "/api/v1/accounts/#{account.id}/captain/skills",
           params: valid_params,
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(Captain::Skill.count).to eq(0)
    end

    it 'creates a workspace skill for an administrator' do
      expect do
        post "/api/v1/accounts/#{account.id}/captain/skills",
             params: valid_params,
             headers: admin.create_new_auth_token,
             as: :json
      end.to change(Captain::Skill, :count).by(1)

      expect(response).to have_http_status(:success)
      expect(json_response).to include(
        name: 'Discovery Script',
        group_name: 'Sales',
        editable: true,
        source_type: 'workspace'
      )
    end
  end

  describe 'PATCH /api/v1/accounts/:account_id/captain/skills/:id' do
    let!(:skill) { create(:captain_skill, account: account, name: 'Old Skill') }

    it 'updates a workspace skill for an administrator' do
      patch "/api/v1/accounts/#{account.id}/captain/skills/#{skill.id}",
            params: { skill: { name: 'Updated Skill', description: 'Updated description', content: 'Updated content' } },
            headers: admin.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response).to include(name: 'Updated Skill', description: 'Updated description')
      expect(skill.reload.content).to eq('Updated content')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/skills/import' do
    let(:skill_markdown) do
      <<~MARKDOWN
        ---
        name: Imported Skill
        description: Imported from GitHub
        metadata:
          category: Support
        ---
        Reply with a short troubleshooting checklist.
      MARKDOWN
    end

    it 'imports GitHub SKILL.md blob URLs as raw workspace skills' do
      allow(Addrinfo).to receive(:getaddrinfo)
        .with('raw.githubusercontent.com', nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
        .and_return([instance_double(Addrinfo, ip_address: '185.199.108.133')])
      stub_request(:get, 'https://raw.githubusercontent.com/acme/repo/main/SKILL.md')
        .to_return(status: 200, body: skill_markdown, headers: { 'Content-Type' => 'text/markdown' })

      expect do
        post "/api/v1/accounts/#{account.id}/captain/skills/import",
             params: { url: 'https://github.com/acme/repo/blob/main/SKILL.md' },
             headers: admin.create_new_auth_token,
             as: :json
      end.to change(Captain::Skill, :count).by(1)

      expect(response).to have_http_status(:success)
      expect(json_response).to include(
        name: 'Imported Skill',
        group_name: 'Support',
        source_url: 'https://raw.githubusercontent.com/acme/repo/main/SKILL.md'
      )
    end

    it 'pins the validated IP address for import fetches to prevent DNS rebinding' do
      http_instances = []
      allow(Net::HTTP).to receive(:new).and_wrap_original do |method, *args|
        method.call(*args).tap do |http|
          allow(http).to receive(:ipaddr=).and_call_original
          http_instances << http
        end
      end
      allow(Addrinfo).to receive(:getaddrinfo)
        .with('skills.example.com', nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
        .and_return([instance_double(Addrinfo, ip_address: '93.184.216.34')])
      stub_request(:get, 'https://skills.example.com/SKILL.md')
        .to_return(status: 200, body: skill_markdown, headers: { 'Content-Type' => 'text/markdown' })

      expect do
        post "/api/v1/accounts/#{account.id}/captain/skills/import",
             params: { url: 'https://skills.example.com/SKILL.md' },
             headers: admin.create_new_auth_token,
             as: :json
      end.to change(Captain::Skill, :count).by(1)

      expect(response).to have_http_status(:success)
      expect(Addrinfo).to have_received(:getaddrinfo).once
      expect(http_instances).not_to be_empty
      expect(http_instances.first).to have_received(:ipaddr=).with('93.184.216.34')
    end

    it 'rejects local import URLs' do
      post "/api/v1/accounts/#{account.id}/captain/skills/import",
           params: { url: 'https://localhost/SKILL.md' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(Captain::Skill.count).to eq(0)
    end

    it 'rejects trailing-dot localhost import URLs' do
      post "/api/v1/accounts/#{account.id}/captain/skills/import",
           params: { url: 'https://localhost./SKILL.md' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(Captain::Skill.count).to eq(0)
    end

    it 'rejects import hosts that resolve to private addresses before fetching' do
      allow(Addrinfo).to receive(:getaddrinfo)
        .with('skills.example.com', nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
        .and_return([instance_double(Addrinfo, ip_address: '10.0.0.7')])
      request = stub_request(:get, 'https://skills.example.com/SKILL.md')

      post "/api/v1/accounts/#{account.id}/captain/skills/import",
           params: { url: 'https://skills.example.com/SKILL.md' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(request).not_to have_been_requested
      expect(Captain::Skill.count).to eq(0)
    end

    it 'rejects import hosts that resolve to IPv4-mapped private IPv6 addresses' do
      allow(Addrinfo).to receive(:getaddrinfo)
        .with('skills.example.com', nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
        .and_return([instance_double(Addrinfo, ip_address: '::ffff:127.0.0.1')])
      request = stub_request(:get, 'https://skills.example.com/SKILL.md')

      post "/api/v1/accounts/#{account.id}/captain/skills/import",
           params: { url: 'https://skills.example.com/SKILL.md' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(request).not_to have_been_requested
      expect(Captain::Skill.count).to eq(0)
    end

    it 'rejects oversized imports from content length before reading the body' do
      allow(Addrinfo).to receive(:getaddrinfo)
        .with('skills.example.com', nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
        .and_return([instance_double(Addrinfo, ip_address: '93.184.216.34')])
      stub_request(:get, 'https://skills.example.com/SKILL.md')
        .to_return(status: 200, body: '', headers: { 'Content-Length' => (201.kilobytes).to_s })

      post "/api/v1/accounts/#{account.id}/captain/skills/import",
           params: { url: 'https://skills.example.com/SKILL.md' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(Captain::Skill.count).to eq(0)
    end
  end

  describe 'DELETE /api/v1/accounts/:account_id/captain/skills/:id' do
    let!(:skill) { create(:captain_skill, account: account) }

    it 'deletes a workspace skill for an administrator' do
      expect do
        delete "/api/v1/accounts/#{account.id}/captain/skills/#{skill.id}",
               headers: admin.create_new_auth_token,
               as: :json
      end.to change(Captain::Skill, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end
  end
end
