require 'rails_helper'

RSpec.describe Captain::Mcp::ClientBuilder do
  let(:mcp_server) do
    instance_double(
      Captain::McpServer,
      id: 42,
      request_timeout: 30,
      client_options: {
        name: 'captain_1_test',
        transport_type: :streamable,
        start: false,
        request_timeout: 5000,
        config: { url: 'https://example.com/mcp' }
      }
    )
  end
  let(:client) { instance_double(RubyLLM::MCP::Client, start: nil, stop: nil) }

  before do
    allow(mcp_server).to receive(:client_options)
      .with(request_timeout_seconds: 5)
      .and_return(
        name: 'captain_1_test',
        transport_type: :streamable,
        start: false,
        request_timeout: 5000,
        config: { url: 'https://example.com/mcp' }
      )
    allow(RubyLLM::MCP).to receive(:client).and_return(client)
  end

  it 'uses the bounded timeout and closes the client after success' do
    result = described_class.with_client(mcp_server, timeout_seconds: 5) do |yielded_client|
      expect(yielded_client).to eq(client)
      'ok'
    end

    expect(result).to eq('ok')
    expect(mcp_server).to have_received(:client_options).with(request_timeout_seconds: 5)
    expect(client).to have_received(:start).once
    expect(client).to have_received(:stop).once
  end

  it 'closes the client when execution raises' do
    expect do
      described_class.with_client(mcp_server, timeout_seconds: 5) do
        raise Timeout::Error, 'discovery timeout'
      end
    end.to raise_error(Timeout::Error, 'discovery timeout')

    expect(client).to have_received(:stop).once
  end

  it 'attempts to close a partially started client' do
    allow(client).to receive(:start).and_raise(SocketError, 'connection failed')

    expect do
      described_class.with_client(mcp_server, timeout_seconds: 5) { 'unreachable' }
    end.to raise_error(SocketError, 'connection failed')

    expect(client).to have_received(:stop).once
  end

  it 'logs cleanup failures without replacing a successful result or exposing transport details' do
    allow(client).to receive(:stop).and_raise(IOError, 'close failed token=secret-value')
    allow(Rails.logger).to receive(:warn)

    result = described_class.with_client(mcp_server, timeout_seconds: 5) { 'ok' }

    expect(result).to eq('ok')
    expect(Rails.logger).to have_received(:warn).with(
      include('client cleanup failed for mcp_server=42: IOError')
    )
    expect(Rails.logger).not_to have_received(:warn).with(include('secret-value'))
  end
end
