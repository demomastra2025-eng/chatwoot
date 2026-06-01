# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Rack::Attack do
  def request_for(path, headers = {})
    Rack::Attack::Request.new(
      Rack::MockRequest.env_for(
        path,
        'REMOTE_ADDR' => '203.0.113.10',
        **headers
      )
    )
  end

  describe 'account-scoped MCP API throttle' do
    subject(:throttle) { described_class.throttles.fetch('/api/v1/accounts/:account_id/mcp') }

    it 'keys only the external MCP endpoint by account and token digest' do
      key = throttle.block.call(
        request_for('/api/v1/accounts/7/mcp', 'HTTP_AUTHORIZATION' => 'Bearer mcp-token')
      )

      expect(key).to eq("7:#{Digest::SHA256.hexdigest('mcp-token')}")
    end

    it 'does not throttle neighboring MCP settings or server admin endpoints' do
      expect(throttle.block.call(request_for('/api/v1/accounts/7/mcp_settings'))).to be_nil
      expect(throttle.block.call(request_for('/api/v1/accounts/7/captain/mcp_servers'))).to be_nil
    end
  end
end
