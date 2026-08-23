require 'rails_helper'

RSpec.describe Whatsapp::CloudMediaDownload do
  let(:channel) do
    instance_double(
      Channel::Whatsapp,
      api_headers: { 'Authorization' => 'Bearer token' },
      media_url: 'https://graph.facebook.test/media-1'
    )
  end
  let(:params) do
    {
      entry: [{
        changes: [{
          value: {
            messages: [{
              id: 'wamid.media-1',
              type: 'image',
              image: { id: 'media-1', mime_type: 'image/jpeg' }
            }]
          }
        }]
      }]
    }.with_indifferent_access
  end

  it 'returns nil without provider I/O for a non-media message' do
    text_params = params.deep_dup
    message = text_params.dig(:entry, 0, :changes, 0, :value, :messages, 0)
    message[:type] = 'text'
    message.delete(:image)
    expect(HTTParty).not_to receive(:get)

    expect(described_class.prepare(channel: channel, params: text_params)).to be_nil
  end

  it 'resolves the provider URL first and downloads the binary only on demand' do
    response = instance_double(
      HTTParty::Response,
      unauthorized?: false,
      success?: true,
      parsed_response: { 'url' => 'https://lookaside.facebook.test/media-1' }
    )
    file = Tempfile.new(['whatsapp-media', '.jpg'])
    allow(HTTParty).to receive(:get)
      .with('https://graph.facebook.test/media-1', headers: { 'Authorization' => 'Bearer token' })
      .and_return(response)
    allow(Down).to receive(:download)
      .with(
        'https://lookaside.facebook.test/media-1',
        headers: { 'Authorization' => 'Bearer token' },
        max_redirects: 0,
        max_size: 40.megabytes
      )
      .and_return(file)
    allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return('40')
    expect(channel).not_to receive(:authorization_error!)

    download = described_class.prepare(channel: channel, params: params)

    expect(Down).not_to have_received(:download)
    expect(download.matches?(id: 'media-1')).to be(true)
    expect(download.download!).to eq(download)
    expect(download.file).to eq(file)
  ensure
    download&.close
  end

  it 'raises so the webhook job retries when Meta rejects the metadata request' do
    response = instance_double(
      HTTParty::Response,
      unauthorized?: false,
      success?: false,
      parsed_response: {}
    )
    allow(HTTParty).to receive(:get).and_return(response)
    expect(Down).not_to receive(:download)

    expect do
      described_class.prepare(channel: channel, params: params)
    end.to raise_error(described_class::MetadataFetchError, 'WhatsApp media metadata request failed')
  end

  it 'raises so the webhook job retries when Meta omits the media URL' do
    response = instance_double(
      HTTParty::Response,
      unauthorized?: false,
      success?: true,
      parsed_response: {}
    )
    allow(HTTParty).to receive(:get).and_return(response)
    expect(Down).not_to receive(:download)

    expect do
      described_class.prepare(channel: channel, params: params)
    end.to raise_error(described_class::MetadataFetchError, 'WhatsApp media metadata response did not include a URL')
  end

  it 'converts an unauthorized response into the retryable metadata error even when bookkeeping raises' do
    response = instance_double(
      HTTParty::Response,
      unauthorized?: true,
      success?: false,
      parsed_response: {}
    )
    allow(HTTParty).to receive(:get).and_return(response)
    allow(channel).to receive(:authorization_error!).and_raise(RuntimeError, 'bookkeeping failed')

    expect do
      described_class.prepare(channel: channel, params: params)
    end.to raise_error(described_class::MetadataFetchError, 'WhatsApp media metadata request failed')
    expect(channel).to have_received(:authorization_error!)
  end

  it 'prepares media from legacy smb message echoes' do
    echo_params = params.deep_dup
    value = echo_params.dig(:entry, 0, :changes, 0, :value)
    value[:smb_message_echoes] = value.delete(:messages)

    download = described_class.new(channel: channel, params: echo_params, outgoing_echo: true)

    expect(download.media_candidate?).to be(true)
    expect(download.matches?(id: 'media-1')).to be(true)
  end
end
