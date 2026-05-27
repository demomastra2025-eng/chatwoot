require 'rails_helper'

RSpec.describe 'ActiveStorage hardening initializer' do
  it 'allows common audio content types to be served inline' do
    expect(Rails.application.config.active_storage.content_types_allowed_inline).to include(
      'audio/webm',
      'audio/ogg',
      'audio/mpeg',
      'audio/mp4',
      'audio/x-m4a',
      'audio/wav',
      'audio/x-wav'
    )
  end

  it 'prepends direct-upload metadata and streaming range guards' do
    expect(ActiveStorage::DirectUploadsController < ActiveStorageDirectUploadMetadataFilter).to be(true)
    expect(ActiveStorage::Streaming < ActiveStorageProxyRangeLimit).to be(true)
  end
end
