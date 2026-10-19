require 'rails_helper'

RSpec.describe Internal::CheckNewVersionsJob do
  subject(:job) { described_class.perform_now }

  it 'updates the latest chatwoot version in redis' do
    data = { 'version' => '1.2.3' }
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ChatwootHub).to receive(:sync_with_hub).and_return(data)
    job
    expect(ChatwootHub).to have_received(:sync_with_hub)
    expect(Redis::Alfred.get(Redis::Alfred::LATEST_CHATWOOT_VERSION)).to eq data['version']
  end

  it 'sends nothing to the hub and keeps the version as it was when the installation did not opt in' do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(RestClient).to receive(:post)
    Redis::Alfred.set(Redis::Alfred::LATEST_CHATWOOT_VERSION, '1.0.0')

    with_modified_env(ENABLE_CHATWOOT_HUB_SYNC: nil) { job }

    expect(RestClient).not_to have_received(:post)
    expect(Redis::Alfred.get(Redis::Alfred::LATEST_CHATWOOT_VERSION)).to eq('1.0.0')
  end

  it 'does not fail when the hub does not answer' do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ChatwootHub).to receive(:sync_with_hub).and_return(nil)

    expect { job }.not_to raise_error
  end
end
