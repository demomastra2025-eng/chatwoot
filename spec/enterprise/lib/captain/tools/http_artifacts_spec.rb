require 'rails_helper'

RSpec.describe 'Captain HTTP tool artifacts' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:custom_tool) do
    create(
      :captain_custom_tool,
      account: account,
      endpoint_url: 'https://files.example.com/orders/{{ order_id }}',
      param_schema: [
        { 'name' => 'order_id', 'type' => 'string', 'description' => 'Order ID', 'required' => true }
      ]
    )
  end

  before do
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('files.example.com').and_return(['93.184.216.34'])
  end

  describe Captain::Tools::HttpRequestExecutor do
    let(:response_body) do
      {
        ok: true,
        invoice_pdf: 'https://files.example.com/downloads/invoice-123.pdf',
        attachment: {
          download_url: 'https://files.example.com/downloads/report-123.csv',
          filename: 'report-123.csv',
          content_type: 'text/csv',
          size_bytes: 321
        }
      }.to_json
    end

    def execute_tool
      stub_request(:get, 'https://files.example.com/orders/123')
        .to_return(status: 200, body: response_body, headers: { 'Content-Type' => 'application/json' })

      described_class.new(
        assistant: assistant,
        custom_tool: custom_tool,
        state: { account_id: account.id, assistant_id: assistant.id }
      ).call(order_id: '123')
    end

    it 'returns structured opaque artifact candidates for file URLs without exposing raw URLs by default' do
      result = execute_tool

      payload = JSON.parse(result)
      expect(custom_tool.allow_file_artifacts).to be(true)
      expect(payload['content']).not_to include('https://files.example.com/downloads/invoice-123.pdf')
      expect(payload['content']).not_to include('https://files.example.com/downloads/report-123.csv')
      expect(payload['content']).to include('[artifact_candidate:1]')
      expect(payload['content']).to include('[artifact_candidate:2]')
      expect(payload['artifact_candidates'].size).to eq(2)

      pdf_candidate = payload['artifact_candidates'].find { |candidate| candidate['filename'] == 'invoice-123.pdf' }
      expect(pdf_candidate).to include(
        'kind' => 'file',
        'source' => 'custom_http_tool',
        'content_type' => 'application/pdf',
        'host' => 'files.example.com',
        'source_path' => 'invoice_pdf'
      )
      expect(pdf_candidate).not_to have_key('url')
      expect(pdf_candidate['id']).to be_present

      decoded_payload = Captain::Tools::HttpArtifactToken.decode(pdf_candidate['id'])
      expect(decoded_payload).to include(
        'account_id' => account.id,
        'assistant_id' => assistant.id,
        'custom_tool_id' => custom_tool.id,
        'url' => 'https://files.example.com/downloads/invoice-123.pdf'
      )
    end

    it 'does not extract hidden raw-response file URLs when response template omits them' do
      custom_tool.update!(response_template: 'Order is ready')

      result = execute_tool

      expect(result).to eq('Order is ready')
    end

    it 'does not expose artifact candidates when file artifacts are disabled for the custom HTTP tool' do
      custom_tool.update!(allow_file_artifacts: false)

      result = execute_tool

      expect(result).to eq(response_body)
    end
  end

  describe Captain::Tools::HttpArtifactMaterializer do
    let(:artifact_id) do
      Captain::Tools::HttpArtifactToken.encode(
        account_id: account.id,
        assistant_id: assistant.id,
        custom_tool_id: custom_tool.id,
        url: 'https://files.example.com/downloads/invoice-123.pdf',
        filename: 'invoice-123.pdf',
        content_type: 'application/pdf',
        size_bytes: 11
      )
    end

    it 'downloads a selected artifact server-side and returns an ActiveStorage signed blob id' do
      stub_request(:get, 'https://files.example.com/downloads/invoice-123.pdf')
        .to_return(
          status: 200,
          body: 'PDF CONTENT',
          headers: { 'Content-Type' => 'application/pdf', 'Content-Length' => '11' }
        )

      signed_blob_id = described_class.new(account: account, assistant: assistant).materialize!(artifact_id)
      blob = ActiveStorage::Blob.find_signed!(signed_blob_id)

      expect(blob.filename.to_s).to eq('invoice-123.pdf')
      expect(blob.content_type).to eq('application/pdf')
      expect(blob.byte_size).to eq(11)
    end

    it 'reuses custom tool auth only for artifacts on the same host as the custom tool endpoint' do
      custom_tool.update!(auth_type: 'bearer', auth_config: { 'token' => 'test-token' })
      stub_request(:get, 'https://files.example.com/downloads/invoice-123.pdf')
        .with(headers: { 'Authorization' => 'Bearer test-token' })
        .to_return(status: 200, body: 'PDF CONTENT', headers: { 'Content-Type' => 'application/pdf' })

      described_class.new(account: account, assistant: assistant).materialize!(artifact_id)

      expect(WebMock).to have_requested(:get, 'https://files.example.com/downloads/invoice-123.pdf')
        .with(headers: { 'Authorization' => 'Bearer test-token' })
    end

    it 'blocks selected artifacts when the account storage limit would be exceeded' do
      stub_request(:get, 'https://files.example.com/downloads/invoice-123.pdf')
        .to_return(status: 200, body: 'PDF CONTENT', headers: { 'Content-Type' => 'application/pdf', 'Content-Length' => '11' })
      storage_service = instance_double(AccountLimits::StorageUsageService, within_limit?: false)
      allow(AccountLimits::StorageUsageService).to receive(:new).with(account: account).and_return(storage_service)

      expect do
        described_class.new(account: account, assistant: assistant).materialize!(artifact_id)
      end.to raise_error(AccountLimits::StorageUsageService::LimitExceeded)
    end
  end
end
