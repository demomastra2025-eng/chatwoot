require 'rails_helper'

RSpec.describe Whatsapp::TemplateSendMediaUploadService do
  let(:channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
  end
  let(:service) { described_class.new(whatsapp_channel: channel) }
  let(:source) do
    channel.template_media_sources.create!(
      template_name: 'product_carousel',
      language: 'en_us',
      card_index: 0,
      media_type: 'image'
    )
  end
  let(:blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('image-bytes'),
      filename: 'product.jpg',
      content_type: 'image/jpeg'
    )
  end

  before do
    source.file.attach(blob)
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v25.0').and_return('v22.0')
    allow(Whatsapp::FacebookApiClient).to receive(:appsecret_proof_query).and_return({})
    allow(Whatsapp::TemplateMediaValidator).to receive(:validate_size!)
    allow(Whatsapp::TemplateMediaValidator).to receive(:validate!).and_return('image/jpeg')
  end

  it 'uploads the retained file to the phone media endpoint and caches its Meta id', :aggregate_failures do
    endpoint = "https://graph.facebook.com/v22.0/#{channel.provider_config['phone_number_id']}/media"
    captured_request = nil
    stub_request(:post, endpoint)
      .with { |request| captured_request = request }
      .to_return(status: 200, body: { id: 'meta-media-42' }.to_json, headers: { 'Content-Type' => 'application/json' })

    expect(service.call(media_type: 'image', source: source)).to eq('meta-media-42')
    expect(service.call(media_type: 'image', source: source)).to eq('meta-media-42')
    expect(source.reload).to have_attributes(meta_media_id: 'meta-media-42')
    expect(source.meta_media_uploaded_at).to be_present
    expect(captured_request.headers['Content-Type']).to start_with('multipart/form-data; boundary=')
    expect(captured_request.body).to include("name=\"messaging_product\"\r\n\r\nwhatsapp\r\n")
    expect(captured_request.body).to include("name=\"type\"\r\n\r\nimage/jpeg\r\n")
    expect(captured_request.body).to match(%r{name="file"; filename="[^"]+"\r\nContent-Type: image/jpeg\r\n\r\nimage-bytes\r\n})
  end

  it 'rejects a retained source that belongs to another channel' do
    other_channel = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )

    expect do
      described_class.new(whatsapp_channel: other_channel).call(media_type: 'image', source: source)
    end.to raise_error(ArgumentError, 'Carousel media file is missing or belongs to another channel')
  end

  it 'rejects direct Cloud upload for non-Cloud providers' do
    channel.provider = 'default'

    expect do
      service.call(media_type: 'image', source: source)
    end.to raise_error(ArgumentError, 'Carousel file upload requires WhatsApp Cloud')
  end
end
