require 'rails_helper'

RSpec.describe Channels::WhatsappWeb::OutgoingEchoJob do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  it 'runs on the whatsappweb_echo queue' do
    expect(described_class.queue_name).to eq('whatsappweb_echo')
  end
end
