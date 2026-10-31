require 'rails_helper'

RSpec.describe Onelink::ExternalHeaders do
  it 'mirrors canonical headers with identical values for existing integrations' do
    headers = { 'X-OneLink-Delivery' => 'test-delivery', 'X-OneLink-Signature' => 'sha256=test', 'Accept' => 'application/json' }
    with_modified_env('ONELINK_LEGACY_EXTERNAL_HEADERS_ENABLED' => nil) do
      expect(described_class.with_legacy_aliases(headers)).to include(
        'X-OneLink-Delivery' => 'test-delivery', 'X-Chatwoot-Delivery' => 'test-delivery',
        'X-OneLink-Signature' => 'sha256=test', 'X-Chatwoot-Signature' => 'sha256=test'
      )
    end
    expect(headers.keys).not_to include('X-Chatwoot-Delivery')
  end

  it 'can retire legacy names after receivers have migrated' do
    with_modified_env('ONELINK_LEGACY_EXTERNAL_HEADERS_ENABLED' => 'false') do
      expect(described_class.with_legacy_aliases('X-OneLink-Account-Id' => '123')).to eq('X-OneLink-Account-Id' => '123')
    end
  end
end
