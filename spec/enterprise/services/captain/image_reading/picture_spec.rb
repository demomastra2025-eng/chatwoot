require 'rails_helper'

RSpec.describe Captain::ImageReading::Picture do
  def encoded(width, height, suffix = '.jpg', bands: 3)
    Vips::Image.black(width, height, bands: bands).new_from_image([120] * bands).write_to_buffer(suffix)
  end

  def dimensions_of(form)
    image = Vips::Image.new_from_buffer(form.bytes, '')
    [image.width, image.height]
  end

  describe '#for_reader' do
    it 'sends an image whose long side is at most 1536 px exactly as it is' do
      bytes = encoded(1536, 900)
      form = described_class.new(bytes: bytes, content_type: 'image/jpeg').for_reader

      expect(form.bytes).to eq(bytes.b)
      expect(form.content_type).to eq('image/jpeg')
    end

    it 'keeps a small png as a png' do
      bytes = encoded(400, 300, '.png')
      form = described_class.new(bytes: bytes, content_type: 'image/png').for_reader

      expect(form.bytes).to eq(bytes.b)
      expect(form.content_type).to eq('image/png')
      expect(form.filename).to eq('image.png')
    end

    it 'shrinks an image whose long side is above 1536 px to a jpeg of 1536 px, keeping its proportions' do
      form = described_class.new(bytes: encoded(3072, 1536, '.png'), content_type: 'image/png').for_reader

      expect(form.content_type).to eq('image/jpeg')
      expect(dimensions_of(form)).to eq([1536, 768])
    end

    it 'resizes only above the limit: 1537 px is resized, 1536 px is not' do
      above = described_class.new(bytes: encoded(1537, 1000), content_type: 'image/jpeg').for_reader
      at_limit_bytes = encoded(1536, 1000)
      at_limit = described_class.new(bytes: at_limit_bytes, content_type: 'image/jpeg').for_reader

      expect(dimensions_of(above)).to eq([1536, 999])
      expect(at_limit.bytes).to eq(at_limit_bytes.b)
    end

    it 'turns a tall image the same way' do
      expect(dimensions_of(described_class.new(bytes: encoded(900, 4000), content_type: 'image/jpeg').for_reader)).to eq([346, 1536])
    end

    it 'converts a small image of a type the providers do not take to a jpeg' do
      form = described_class.new(bytes: encoded(300, 200, '.tif'), content_type: 'image/tiff').for_reader

      expect(form.content_type).to eq('image/jpeg')
      expect(dimensions_of(form)).to eq([300, 200])
    end

    it 'flattens transparency when it makes a jpeg' do
      form = described_class.new(bytes: encoded(2000, 100, '.png', bands: 4), content_type: 'image/png').for_reader

      expect(form.content_type).to eq('image/jpeg')
      expect(Vips::Image.new_from_buffer(form.bytes, '').has_alpha?).to be(false)
    end
  end

  describe '#for_router' do
    it 'is always a jpeg whose long side is at most 1024 px' do
      form = described_class.new(bytes: encoded(2400, 1200, '.png'), content_type: 'image/png').for_router

      expect(form.content_type).to eq('image/jpeg')
      expect(dimensions_of(form)).to eq([1024, 512])
    end

    it 'does not enlarge a small image' do
      expect(dimensions_of(described_class.new(bytes: encoded(500, 400), content_type: 'image/jpeg').for_router)).to eq([500, 400])
    end

    it 'is a data url the router can send' do
      form = described_class.new(bytes: encoded(500, 400), content_type: 'image/jpeg').for_router

      expect(form.data_url).to start_with('data:image/jpeg;base64,')
      expect(Base64.strict_decode64(form.data_url.split(',', 2).last)).to eq(form.bytes)
    end
  end

  describe '#content_type' do
    it 'is read from the bytes, not trusted from what the channel declared' do
      picture = described_class.new(bytes: encoded(100, 100, '.png'), content_type: 'application/octet-stream')

      expect(picture.content_type).to eq('image/png')
    end
  end

  describe 'a file that cannot be read' do
    it 'refuses empty bytes' do
      expect { described_class.new(bytes: '', content_type: 'image/jpeg') }.to raise_error(described_class::Unreadable)
    end

    it 'refuses a file that is not an image' do
      expect { described_class.new(bytes: "%PDF-1.4\n%\xE2\xE3\n".b, content_type: 'image/jpeg') }
        .to raise_error(described_class::Unreadable, /not an image/)
    end

    it 'refuses a damaged image when its size is asked' do
      picture = described_class.new(bytes: "\xFF\xD8\xFF\xE0\x00\x10JFIF damaged".b, content_type: 'image/jpeg')

      expect { picture.for_reader }.to raise_error(described_class::Unreadable, /cannot be decoded/)
    end
  end

  describe '.load' do
    let(:account) { create(:account) }
    let(:message) { create(:message, account: account) }
    let(:bytes) { encoded(640, 480) }

    it 'reads the file of the attachment from the storage and never goes to the network' do
      attachment = message.attachments.create!(account_id: account.id, file_type: :image)
      attachment.file.attach(io: StringIO.new(bytes), filename: 'photo.jpg', content_type: 'image/jpeg')
      allow(SafeFetch).to receive(:fetch)

      picture = described_class.load(attachment: attachment, url: attachment.file_url)

      expect(picture.content_type).to eq('image/jpeg')
      expect(picture.for_reader.bytes).to eq(bytes.b)
      expect(SafeFetch).not_to have_received(:fetch)
    end

    it 'fetches the external link of an image that has no file, through the safe fetch, images only' do
      attachment = message.attachments.create!(account_id: account.id, file_type: :image, external_url: 'https://cdn.example.com/p.jpg')
      tempfile = Tempfile.new(['p', '.jpg'], binmode: true).tap { |file| file.write(bytes) && file.rewind }
      result = SafeFetch::Result.new(tempfile: tempfile, filename: 'p.jpg', content_type: 'image/jpeg')
      allow(SafeFetch).to receive(:fetch).and_yield(result)

      picture = described_class.load(attachment: attachment, url: attachment.external_url)

      expect(picture.for_reader.bytes).to eq(bytes.b)
      expect(SafeFetch).to have_received(:fetch)
        .with('https://cdn.example.com/p.jpg', hash_including(allowed_content_type_prefixes: ['image/']))
    end

    it 'names no link in the error when the fetch fails' do
      allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::UnsafeUrlError, 'resolved to https://10.0.0.1/secret')

      expect { described_class.load(attachment: nil, url: 'https://cdn.example.com/p.jpg') }
        .to raise_error(described_class::Unreadable) { |error| expect(error.message).not_to include('10.0.0.1', 'example.com') }
    end

    it 'refuses a call without any source' do
      expect { described_class.load(attachment: nil, url: nil) }.to raise_error(described_class::Unreadable, /no source/)
    end

    it 'refuses a stored file larger than the limit before downloading it' do
      attachment = message.attachments.create!(account_id: account.id, file_type: :image)
      attachment.file.attach(io: StringIO.new(bytes), filename: 'photo.jpg', content_type: 'image/jpeg')
      stub_const("#{described_class}::MAX_ORIGINAL_BYTES", 10)

      expect { described_class.load(attachment: attachment, url: nil) }.to raise_error(described_class::Unreadable, /too large/)
    end
  end
end
