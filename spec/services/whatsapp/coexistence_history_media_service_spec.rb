require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceHistoryMediaService do
  let(:channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      provider_config: {
        'api_key' => 'token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => {
          'state' => 'history_failed',
          'history_failed_messages' => %w[one two].map do |suffix|
            {
              'id' => "wamid.media-#{suffix}",
              'kind' => 'history_media',
              'message' => {
                'id' => "wamid.media-#{suffix}",
                'type' => 'image',
                'image' => { 'id' => "media-#{suffix}" }
              },
              'metadata' => { 'phone_number_id' => 'phone-1' },
              'replayable' => true
            }
          end
        }
      }
    )
  end

  it 'reconciles only explicitly selected persisted media failures' do
    service = described_class.new(channel: channel, value: {})
    allow(service).to receive(:hydrate)

    failures = service.replay_pending(only_ids: ['wamid.media-one'])
    service.finalize(failures)

    expect(service).to have_received(:hydrate).once.with(
      hash_including(id: 'wamid.media-one'),
      metadata: hash_including(phone_number_id: 'phone-1')
    )
    expect(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages'))
      .to contain_exactly(include('id' => 'wamid.media-two'))
  end
end
