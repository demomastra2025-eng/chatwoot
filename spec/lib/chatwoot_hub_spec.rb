require 'rails_helper'

describe ChatwootHub do
  describe '.base_url' do
    it 'uses the static hub url' do
      expect(described_class::DEFAULT_BASE_URL).to eq('https://hub.2.chatwoot.com')
      expect(described_class.base_url).to eq('https://hub.2.chatwoot.com')
    end
  end

  it 'generates installation identifier' do
    installation_identifier = described_class.installation_identifier
    expect(installation_identifier).not_to be_nil
    expect(described_class.installation_identifier).to eq installation_identifier
  end

  describe '.sync_enabled?' do
    it 'is off unless the installation opts in' do
      with_modified_env ENABLE_CHATWOOT_HUB_SYNC: nil do
        expect(described_class.sync_enabled?).to be(false)
      end
    end

    it 'is off for anything that is not an explicit yes' do
      ['', 'false', '0', 'no', 'off', 'maybe', 'tru'].each do |value|
        with_modified_env ENABLE_CHATWOOT_HUB_SYNC: value do
          expect(described_class.sync_enabled?).to be(false), value.inspect
        end
      end
    end

    it 'is on for an explicit yes' do
      %w[true 1 TRUE yes on].each do |value|
        with_modified_env ENABLE_CHATWOOT_HUB_SYNC: value do
          expect(described_class.sync_enabled?).to be(true), value
        end
      end
    end
  end

  context 'when the installation did not opt in' do
    before do
      allow(RestClient).to receive(:post)
    end

    it 'asks nothing of the hub and sends nothing to it' do
      with_modified_env ENABLE_CHATWOOT_HUB_SYNC: nil do
        expect(described_class.sync_with_hub).to be_nil
        expect(described_class.register_instance('test', 'test', 'test@test.com')).to be_nil
        expect(described_class.emit_event('sample_event', { 'a' => 1 })).to be_nil
        expect(RestClient).not_to have_received(:post)
      end
    end

    it 'still relays push notifications, which are a function and not telemetry' do
      with_modified_env ENABLE_CHATWOOT_HUB_SYNC: nil do
        described_class.send_push_with_response({ token: 'device-token' })

        expect(RestClient).to have_received(:post).with(described_class.push_notification_url, anything, anything)
      end
    end
  end

  context 'when fetching sync_with_hub' do
    around do |example|
      with_modified_env(ENABLE_CHATWOOT_HUB_SYNC: 'true') { example.run }
    end

    it 'get latest version from chatwoot hub' do
      version = '1.1.1'
      allow(RestClient).to receive(:post).and_return({ version: version }.to_json)
      expect(described_class.sync_with_hub['version']).to eq version
      expect(RestClient).to have_received(:post).with(described_class.ping_url, described_class.instance_config
        .merge(described_class.instance_metrics).to_json, { content_type: :json, accept: :json })
    end

    it 'will not send instance metrics when telemetry is disabled' do
      version = '1.1.1'
      with_modified_env DISABLE_TELEMETRY: 'true' do
        allow(RestClient).to receive(:post).and_return({ version: version }.to_json)
        expect(described_class.sync_with_hub['version']).to eq version
        expect(RestClient).to have_received(:post).with(described_class.ping_url,
                                                        described_class.instance_config.to_json, { content_type: :json, accept: :json })
      end
    end

    it 'returns nil when chatwoot hub is down' do
      allow(RestClient).to receive(:post).and_raise(ExceptionList::REST_CLIENT_EXCEPTIONS.sample)
      expect(described_class.sync_with_hub).to be_nil
    end
  end

  context 'when register instance' do
    let(:company_name) { 'test' }
    let(:owner_name) { 'test' }
    let(:owner_email) { 'test@test.com' }

    around do |example|
      with_modified_env(ENABLE_CHATWOOT_HUB_SYNC: 'true') { example.run }
    end

    it 'sends info of registration' do
      info = { company_name: company_name, owner_name: owner_name, owner_email: owner_email, subscribed_to_mailers: true }
      allow(RestClient).to receive(:post)
      described_class.register_instance(company_name, owner_name, owner_email)
      expect(RestClient).to have_received(:post).with(described_class.registration_url,
                                                      info.merge(described_class.instance_config).to_json, { content_type: :json, accept: :json })
    end
  end

  context 'when sending push notifications' do
    let(:fcm_options) { { token: 'device-token', notification: { title: 'Test', body: 'Body' } } }
    let(:payload) { { fcm_options: fcm_options }.merge(described_class.instance_config).to_json }

    it 'sends push via hub and returns the raw response for diagnostics' do
      response = instance_double(RestClient::Response)
      allow(RestClient).to receive(:post).and_return(response)

      expect(described_class.send_push_with_response(fcm_options)).to eq(response)
      expect(RestClient).to have_received(:post).with(
        described_class.push_notification_url,
        payload,
        { content_type: :json, accept: :json }
      )
    end

    it 'keeps legacy send_push rescue behavior while delegating to the response method' do
      allow(RestClient).to receive(:post).and_raise(RestClient::Exception)
      allow(Rails.logger).to receive(:error)

      expect { described_class.send_push(fcm_options) }.not_to raise_error
      expect(Rails.logger).to have_received(:error)
    end
  end

  context 'when sending events' do
    let(:event_name) { 'sample_event' }
    let(:event_data) { { 'sample_data' => 'sample_data' } }

    around do |example|
      with_modified_env(ENABLE_CHATWOOT_HUB_SYNC: 'true') { example.run }
    end

    it 'will send instance events' do
      info = { event_name: event_name, event_data: event_data }
      allow(RestClient).to receive(:post)
      described_class.emit_event(event_name, event_data)
      expect(RestClient).to have_received(:post).with(described_class.events_url,
                                                      info.merge(described_class.instance_config).to_json, { content_type: :json, accept: :json })
    end

    it 'will not send instance events when telemetry is disabled' do
      with_modified_env DISABLE_TELEMETRY: 'true' do
        info = { event_name: event_name, event_data: event_data }
        allow(RestClient).to receive(:post)
        described_class.emit_event(event_name, event_data)
        expect(RestClient).not_to have_received(:post)
          .with(described_class.events_url,
                info.merge(described_class.instance_config).to_json, { content_type: :json, accept: :json })
      end
    end
  end
end
