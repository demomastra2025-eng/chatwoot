require 'rails_helper'

RSpec.describe Whatsapp::TemplateMediaValidator do
  let(:io) { StringIO.new('media-bytes') }

  it 'uses the shared two-megabyte template media limit' do
    expect(described_class::MAX_FILE_SIZE).to eq(2.megabytes)
  end

  it 'returns the detected MIME type and rewinds the stream' do
    io.read(3)
    allow(Marcel::MimeType).to receive(:for).with(io).and_return('image/png')

    content_type = described_class.validate!(
      io: io,
      file_name: 'sample.png',
      media_type: 'image',
      byte_size: io.size
    )

    expect(content_type).to eq('image/png')
    expect(io.pos).to be_zero
  end

  it 'rejects oversized files before MIME detection' do
    expect(Marcel::MimeType).not_to receive(:for)

    expect do
      described_class.validate!(
        io: io,
        file_name: 'sample.mp4',
        media_type: 'video',
        byte_size: described_class::MAX_FILE_SIZE + 1
      )
    end.to raise_error(described_class::InvalidMediaError, 'Uploaded media file is too large')
  end

  it 'rejects an unsupported header media type before MIME detection' do
    expect(Marcel::MimeType).not_to receive(:for)

    expect do
      described_class.validate!(
        io: io,
        file_name: 'sample.gif',
        media_type: 'animation',
        byte_size: io.size
      )
    end.to raise_error(described_class::InvalidMediaError, 'Unsupported header media type: animation')
  end

  it 'accepts a file exactly at the size boundary' do
    allow(Marcel::MimeType).to receive(:for).with(io).and_return('image/png')

    expect(
      described_class.validate!(
        io: io,
        file_name: 'sample.png',
        media_type: 'image',
        byte_size: described_class::MAX_FILE_SIZE
      )
    ).to eq('image/png')
  end

  it 'rejects content that does not match the requested media type' do
    allow(Marcel::MimeType).to receive(:for).with(io).and_return('application/pdf')

    expect do
      described_class.validate!(
        io: io,
        file_name: 'sample.pdf',
        media_type: 'image',
        byte_size: io.size
      )
    end.to raise_error(described_class::InvalidMediaError, 'Unsupported image file type: application/pdf')
    expect(io.pos).to be_zero
  end

  [['evil.jpg', 'image'], ['evil.pdf', 'document'], ['evil.mp4', 'video']].each do |file_name, media_type|
    it "rejects unrecognized bytes instead of trusting the #{File.extname(file_name)} extension" do
      invalid_io = StringIO.new('not-valid-template-media')

      expect do
        described_class.validate!(
          io: invalid_io,
          file_name: file_name,
          media_type: media_type,
          byte_size: invalid_io.size
        )
      end.to raise_error(described_class::InvalidMediaError, %r{application/octet-stream})
    end
  end
end
