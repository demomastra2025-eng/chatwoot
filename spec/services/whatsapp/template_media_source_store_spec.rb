require 'rails_helper'

RSpec.describe Whatsapp::TemplateMediaSourceStore do
  let(:channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
  end
  let(:service) { described_class.new(whatsapp_channel: channel) }

  def create_upload_blob(file_name = 'product.jpg')
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('template-media'),
      filename: file_name,
      content_type: 'image/jpeg',
      metadata: {
        'account_id' => channel.account_id,
        'upload_purpose' => Whatsapp::TemplateAssetUploadService::UPLOAD_PURPOSE
      }
    )
  end

  def carousel_config(blob)
    {
      name: 'product_carousel',
      language: 'en_US',
      carousel_cards: [{
        header_type: 'image',
        sample_media_blob_id: blob.signed_id(
          purpose: "whatsapp_template_media:account:#{channel.account_id}"
        ),
        sample_media_url: 'https://app.one-link.kz/rails/active_storage/blobs/product.jpg'
      }]
    }
  end

  it 'retains the author upload as a file-backed source for the template card' do
    blob = create_upload_blob

    sources = service.replace!(carousel_config(blob))

    expect(sources.size).to eq(1)
    expect(sources.first).to have_attributes(
      template_name: 'product_carousel',
      language: 'en_us',
      card_index: 0,
      media_type: 'image',
      source_url: nil
    )
    expect(sources.first.file.blob).to eq(blob)
  end

  it 'replaces prior card sources and deletes every language on template removal' do
    first_blob = create_upload_blob('first.jpg')
    second_blob = create_upload_blob('second.jpg')
    service.replace!(carousel_config(first_blob))

    service.replace!(carousel_config(second_blob))

    expect(channel.template_media_sources.count).to eq(1)
    expect(channel.template_media_sources.first.file.blob).to eq(second_blob)

    service.delete!('product_carousel')
    expect(channel.template_media_sources.reload).to be_empty
  end

  it 'decorates only matching cached carousel cards without exposing a blob reference' do
    blob = create_upload_blob
    service.replace!(carousel_config(blob))
    channel.update!(message_templates: [{
                      'name' => 'product_carousel',
                      'language' => 'en_US',
                      'components' => [{
                        'type' => 'CAROUSEL',
                        'cards' => [{
                          'components' => [{ 'type' => 'HEADER', 'format' => 'IMAGE' }]
                        }]
                      }]
                    }])

    presented = Whatsapp::TemplateMediaSourcePresenter.new(whatsapp_channel: channel).perform
    header = presented.dig(0, 'components', 0, 'cards', 0, 'components', 0)

    expect(presented.first['one_link_carousel_media_upload_supported']).to be(true)
    expect(header['one_link_media']).to eq('attached' => true, 'file_name' => 'product.jpg')
    expect(header.to_s).not_to include(blob.signed_id)
    expect(channel.message_templates.dig(0, 'components', 0, 'cards', 0, 'components', 0)).not_to have_key('one_link_media')
  end

  it 'does not attach attempted duplicate media to a remote template with a different carousel shape' do
    blob = create_upload_blob
    mismatched_template = {
      'components' => [{
        'type' => 'CAROUSEL',
        'cards' => [{ 'components' => [{ 'type' => 'HEADER', 'format' => 'VIDEO' }] }]
      }]
    }

    expect(service.replace!(carousel_config(blob), template: mismatched_template)).to eq([])
    expect(channel.template_media_sources).to be_empty
  end

  it 'retains the fallback URL when the temporary blob expired after provider upload' do
    blob = create_upload_blob
    config = carousel_config(blob)
    blob.purge
    matching_template = {
      'components' => [{
        'type' => 'CAROUSEL',
        'cards' => [{ 'components' => [{ 'type' => 'HEADER', 'format' => 'IMAGE' }] }]
      }]
    }

    sources = service.replace!(config, template: matching_template)

    expect(sources.one?).to be(true)
    expect(sources.first).to have_attributes(
      source_url: 'https://app.one-link.kz/rails/active_storage/blobs/product.jpg',
      media_type: 'image'
    )
    expect(sources.first.file).not_to be_attached
  end

  it 'does not advertise retained Cloud media after switching to a legacy provider' do
    blob = create_upload_blob
    service.replace!(carousel_config(blob))
    channel.update!(
      provider: 'default',
      message_templates: [{
        'name' => 'product_carousel',
        'language' => 'en_US',
        'components' => [{
          'type' => 'CAROUSEL',
          'cards' => [{ 'components' => [{ 'type' => 'HEADER', 'format' => 'IMAGE' }] }]
        }]
      }]
    )

    presented = Whatsapp::TemplateMediaSourcePresenter.new(whatsapp_channel: channel).perform
    header = presented.dig(0, 'components', 0, 'cards', 0, 'components', 0)

    expect(presented.first['one_link_carousel_media_upload_supported']).to be(false)
    expect(header).not_to have_key('one_link_media')
  end
end
