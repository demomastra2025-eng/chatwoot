require 'rails_helper'

RSpec.describe Captain::OpenAiMessageBuilderService do
  subject(:service) { described_class.new(message: message, assistant: assistant) }

  let(:message) { create(:message, content: 'Hello world') }
  let(:assistant) do
    create(:captain_assistant, account: message.account,
                               config: { 'feature_document_reading' => true, 'feature_image_understanding' => true })
  end
  let(:image_recognition_service) { instance_double(Captain::ImageRecognitionService, perform: 'Recognized image content') }

  before do
    allow(Captain::ImageRecognitionService).to receive(:new).and_return(image_recognition_service)
    allow(Captain::ImageRecognitionService).to receive(:cached_description).and_return('Recognized image content')
    allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
  end

  describe '#generate_content' do
    context 'when message has only text content' do
      it 'returns the text content directly' do
        expect(service.generate_content).to eq('Hello world')
      end
    end

    context 'when message has Meta Ads referral attributes' do
      let(:message) do
        create(
          :message,
          content: 'Здравствуйте! Можно узнать? ',
          content_attributes: {
            meta_referral: {
              provider: 'whatsapp',
              attribution_type: 'click_to_whatsapp_ad',
              headline: 'Напишите нам',
              body: 'Для подробной информации напишите нам в Whatsapp',
              source_url: 'https://www.instagram.com/p/DaKpBgpMIJU/',
              ad_id: '120247627354820016',
              ctwa_clid: 'very-long-click-id'
            }
          }
        )
      end

      it 'includes a compact ad context for Captain without raw referral payloads' do
        result = service.generate_content

        expect(result).to include({ type: 'text', text: 'Здравствуйте! Можно узнать? ' })
        context_part = result.find do |part|
          part[:type] == 'text' && part[:text].include?('Meta Ads referral context')
        end

        expect(context_part[:text]).to include(
          'Meta Ads referral context for this incoming lead:',
          'channel: whatsapp',
          'attribution: click_to_whatsapp_ad',
          'headline: Напишите нам',
          'ad text: Для подробной информации напишите нам в Whatsapp',
          'source URL: https://www.instagram.com/p/DaKpBgpMIJU/',
          'ad id: 120247627354820016',
          'ctwa click id: present'
        )
        expect(context_part[:text]).not_to include('very-long-click-id')
      end
    end

    context 'when Meta Ads referral attributes use frontend camelCase keys' do
      let(:message) do
        create(
          :message,
          content: 'Interested',
          content_attributes: {
            metaReferral: {
              provider: 'instagram',
              attributionType: 'click_to_direct_ad',
              sourceUrl: 'https://www.instagram.com/p/lead/',
              adId: 'ig-ad-1',
              sourceId: 'ig-source-1',
              mediaType: 'image',
              ctwaClid: 'camel-click-id'
            }
          }
        )
      end

      it 'normalizes camelCase details and keeps the click id bounded' do
        context_part = service.generate_content.find do |part|
          part[:type] == 'text' && part[:text].include?('Meta Ads referral context')
        end

        expect(context_part[:text]).to include(
          'channel: instagram',
          'attribution: click_to_direct_ad',
          'source URL: https://www.instagram.com/p/lead/',
          'ad id: ig-ad-1',
          'source id: ig-source-1',
          'media type: image',
          'ctwa click id: present'
        )
        expect(context_part[:text]).not_to include('camel-click-id')
      end
    end

    context 'when Meta Ads referral attributes are malformed' do
      let(:message) do
        create(
          :message,
          content: 'Hello world',
          content_attributes: { meta_referral: 'not-a-hash' }
        )
      end

      it 'ignores the malformed context without breaking message generation' do
        expect(service.generate_content).to eq('Hello world')
      end
    end

    context 'when Meta Ads referral has many fields plus a click id' do
      let(:message) do
        create(
          :message,
          content: 'Lead',
          content_attributes: {
            meta_referral: {
              provider: 'facebook',
              attribution_type: 'click_to_messenger_ad',
              source: 'ADS',
              source_type: 'ADS',
              headline: 'Headline',
              body: 'Body',
              media_type: 'image',
              source_url: 'https://example.com/ad',
              ad_id: 'ad-1',
              source_id: 'source-1',
              post_id: 'post-1',
              product_id: 'product-1',
              flow_id: 'flow-1',
              ref: 'ref-1',
              referral_type: 'OPEN_THREAD',
              received_at: '2026-07-02T00:00:00Z',
              ctwa_clid: 'hidden-click-id'
            }
          }
        )
      end

      it 'keeps the click-id presence signal inside the bounded context' do
        context_part = service.generate_content.find do |part|
          part[:type] == 'text' && part[:text].include?('Meta Ads referral context')
        end

        expect(context_part[:text].lines.drop(1).grep(/:/).size).to be <= 16
        expect(context_part[:text]).to include('ctwa click id: present')
        expect(context_part[:text]).not_to include('hidden-click-id')
      end
    end

    context 'when message has no content and no attachments' do
      let(:message) { create(:message, content: nil) }

      it 'returns default message' do
        expect(service.generate_content).to eq('Message without content')
      end
    end

    context 'when message has text content and attachments' do
      before do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :image, external_url: 'https://example.com/image.jpg')
        attachment.save!
      end

      it 'returns an array of content parts' do
        result = service.generate_content
        expect(result).to be_an(Array)
        expect(result).to include({ type: 'text', text: 'Hello world' })
        expect(result).not_to include(hash_including(type: 'image_url'))
        expect(result).to include({ type: 'text', text: 'Image attachment: Recognized image content' })
      end
    end

    context 'when message has only non-text attachments' do
      let(:message) { create(:message, content: nil) }

      before do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :image, external_url: 'https://example.com/image.jpg')
        attachment.save!
      end

      it 'returns recognized image text without forwarding an external URL' do
        expect(service.generate_content).to eq('Image attachment: Recognized image content')
      end
    end
  end

  describe '#attachment_parts' do
    let(:message) { create(:message, content: nil) }
    let(:attachments) { message.attachments }

    context 'with image attachments' do
      before do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :image, external_url: 'https://example.com/image.jpg')
        attachment.save!
      end

      it 'includes image parts' do
        result = service.send(:attachment_parts, attachments)
        expect(result).not_to include(hash_including(type: 'image_url'))
        expect(result).to include({ type: 'text', text: 'Image attachment: Recognized image content' })
      end
    end

    context 'with audio attachments' do
      let(:audio_attachment) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :audio)
        attachment.save!
        attachment
      end

      before do
        message.account.update!(audio_transcriptions: true)
      end

      it 'includes stored transcription text part without transcribing synchronously' do
        audio_attachment # trigger creation
        audio_attachment.update!(meta: { 'transcribed_text' => 'Audio transcription text' })

        expect(Messages::AudioTranscriptionService).not_to receive(:new)

        result = service.send(:attachment_parts, attachments)
        expect(result).to include({ type: 'text', text: 'Audio transcription text' })
      end

      it 'omits stored transcription when the AI agent capability is disabled' do
        assistant = create(:captain_assistant, account: message.account, config: { 'use_audio_transcriptions' => false })
        audio_attachment.update!(meta: { 'transcribed_text' => 'Hidden from this agent' })

        result = described_class.new(message: message, assistant: assistant).send(:attachment_parts, attachments)

        expect(result).not_to include({ type: 'text', text: 'Hidden from this agent' })
      end
    end

    context 'with other file types' do
      before do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :file)
        attachment.save!
      end

      it 'includes generic attachment message' do
        result = service.send(:attachment_parts, attachments)
        expect(result).to include({ type: 'text', text: 'User has shared an attachment' })
      end
    end

    context 'with parsed document attachments' do
      let(:document_attachment) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :file)
        attachment.file.attach(io: StringIO.new('pdf'), filename: 'contract.pdf', content_type: 'application/pdf')
        attachment.save!
        attachment
      end

      before do
        message.account.enable_features!('captain_integration')
      end

      it 'includes stored document text instead of a generic attachment placeholder' do
        document_attachment.update!(meta: { 'parsed_text' => 'Contract terms text' })

        result = service.send(:attachment_parts, attachments)

        expect(result).to include(
          { type: 'text', text: "Document attachment: contract.pdf\nContract terms text" }
        )
        expect(result).not_to include({ type: 'text', text: 'User has shared an attachment' })
      end

      it 'does not expose parsed document text when the assistant capability is disabled' do
        assistant.update!(config: { 'feature_document_reading' => false })
        document_attachment.update!(meta: { 'parsed_text' => 'Contract terms text' })

        result = service.send(:attachment_parts, attachments)

        expect(result).not_to include(
          { type: 'text', text: "Document attachment: contract.pdf\nContract terms text" }
        )
        expect(result).to include({ type: 'text', text: 'User has shared file attachment(s): contract.pdf' })
      end

      it 'does not expose cached document text when Firecrawl is unavailable' do
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)
        document_attachment.update!(meta: { 'parsed_text' => 'Contract terms text' })

        result = service.send(:attachment_parts, attachments)

        expect(result).not_to include(
          { type: 'text', text: "Document attachment: contract.pdf\nContract terms text" }
        )
        expect(result).to include({ type: 'text', text: 'User has shared file attachment(s): contract.pdf' })
      end
    end

    context 'with mixed attachment types' do
      let(:image_attachment) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :image, external_url: 'https://example.com/image.jpg')
        attachment.save!
        attachment
      end

      let(:audio_attachment) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :audio)
        attachment.save!
        attachment
      end

      let(:document_attachment) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :file)
        attachment.save!
        attachment
      end

      before do
        message.account.update!(audio_transcriptions: true)
      end

      it 'includes all relevant parts' do
        image_attachment    # trigger creation
        audio_attachment    # trigger creation
        document_attachment # trigger creation
        audio_attachment.update!(meta: { 'transcribed_text' => 'Audio text' })

        expect(Messages::AudioTranscriptionService).not_to receive(:new)

        result = service.send(:attachment_parts, attachments)
        expect(result).not_to include(hash_including(type: 'image_url'))
        expect(result).to include({ type: 'text', text: 'Image attachment: Recognized image content' })
        expect(result).to include({ type: 'text', text: 'Audio text' })
        expect(result).to include({ type: 'text', text: 'User has shared an attachment' })
      end
    end
  end

  describe '#image_parts' do
    let(:message) { create(:message, content: nil) }

    it 'does not send an extensionless loopback URL to RubyLLM even with a cached description' do
      attachment = message.attachments.create!(account: message.account, file_type: :image,
                                               external_url: 'http://127.0.0.1/internal')
      allow(Captain::ImageRecognitionService).to receive(:cached_description).and_return('Cached receipt')
      expect(Captain::ImageRecognitionService).not_to receive(:new)
      parts = described_class.new(message: message, assistant: assistant,
                                  image_description_attachment_ids: [attachment.id]).generate_content

      expect(parts).to eq('Image attachment: Cached receipt')
      expect(Llm::MessageFormat.extract_text_and_attachments(parts).last).to be_empty
    end

    it 'sends a bounded stored image through RubyLLM without fetching an untrusted URL' do
      attachment = message.attachments.create!(account: message.account, file_type: :image,
                                               external_url: 'http://127.0.0.1/internal')
      attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open,
                             filename: 'avatar.png', content_type: 'image/png')
      parts = described_class.new(message: message, assistant: assistant,
                                  image_description_attachment_ids: [attachment.id]).generate_content

      expect(parts).not_to include(hash_including(image_url: hash_including(url: 'http://127.0.0.1/internal')))
      content = Llm::MessageFormat.build_content(parts)
      expect(content.attachments.one?).to be(true)
      expect(content.attachments.first.source).to eq(attachment.file.blob)
      expect(RubyLLM::Providers::OpenAI::Media.format_content(content).last.dig(:image_url, :url)).to start_with('data:image/png;base64,')
    end

    it 'limits raw image media to the selected recent attachments while retaining older descriptions' do
      attachments = 4.times.map do
        item = message.attachments.create!(account: message.account, file_type: :image)
        item.file.attach(io: Rails.root.join('spec/assets/avatar.png').open,
                         filename: "image-#{item.id}.png", content_type: 'image/png')
        item
      end
      parts = described_class.new(message: message, assistant: assistant,
                                  image_description_attachment_ids: attachments.last(2).map(&:id)).generate_content

      expect(parts.count { |part| part[:type] == 'image_url' }).to eq(2)
      expect(parts.count { |part| part[:type] == 'text' && part[:text].start_with?('Image attachment:') }).to eq(4)
    end

    context 'with external image attachments' do
      let(:image1) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :image, external_url: 'https://example.com/image1.jpg')
        attachment.save!
        attachment
      end

      let(:image2) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :image, external_url: 'https://example.com/image2.jpg')
        attachment.save!
        attachment
      end

      it 'keeps the descriptions for all images without forwarding their URLs' do
        image1 # trigger creation
        image2 # trigger creation

        image_attachments = message.attachments.where(file_type: :image)
        result = service.send(:image_parts, image_attachments)

        expect(result).not_to include(hash_including(type: 'image_url'))
        expect(result.count { |part| part == { type: 'text', text: 'Image attachment: Recognized image content' } }).to eq(2)
      end
    end

    context 'with image attachments without URLs' do
      let(:image_attachment) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :image, external_url: nil)
        attachment.save!
        attachment
      end

      before do
        allow(image_attachment).to receive(:file).and_return(instance_double(ActiveStorage::Attached::One, attached?: false))
      end

      it 'keeps the image description without exposing a URL when none is available' do
        image_attachment # trigger creation

        image_attachments = message.attachments.where(file_type: :image)
        result = service.send(:image_parts, image_attachments)

        expect(result).not_to include(hash_including(type: 'image_url'))
        expect(result).to include({ type: 'text', text: 'Image attachment: Recognized image content' })
      end
    end

    it 'does not expose the URL or cached image text when image understanding is disabled' do
      assistant.update!(config: assistant.config.merge('feature_image_understanding' => false))
      message.attachments.create!(account: message.account, file_type: :image,
                                  external_url: 'https://example.com/private-receipt.jpg')

      expect(Captain::ImageRecognitionService).not_to receive(:new)
      result = service.send(:image_parts, message.attachments.where(file_type: :image))

      expect(result).to eq([{ type: 'text', text: 'Image attachment: User shared an image' }])
    end

    it 'does not expose an unsafe image URL even when vision is enabled' do
      message.attachments.create!(account: message.account, file_type: :image, external_url: 'file:///etc/passwd')

      result = service.send(:image_parts, message.attachments.where(file_type: :image))

      expect(result).not_to include(hash_including(type: 'image_url'))
    end
  end

  describe '#image_source' do
    let(:attachment) do
      attachment = message.attachments.build(account_id: message.account_id, file_type: :image)
      attachment.save!
      attachment
    end

    context 'when attachment has external_url' do
      before { attachment.update(external_url: 'https://example.com/image.jpg') }

      it 'does not trust the external URL' do
        expect(service.send(:image_source, attachment)).to be_nil
      end
    end

    context 'when attachment has attached file' do
      before do
        attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open,
                               filename: 'avatar.png', content_type: 'image/png')
      end

      it 'returns the stored blob rather than a redirect or download URL' do
        expect(service.send(:image_source, attachment)).to eq(attachment.file.blob)
      end

      it 'rejects an oversized image without downloading it' do
        allow(attachment.file.blob).to receive(:byte_size).and_return(described_class::MAX_IMAGE_BYTES + 1)
        expect(attachment.file.blob).not_to receive(:download)
        expect(service.send(:image_source, attachment)).to be_nil
      end

      it 'rejects a non-image blob even when the attachment is labelled image' do
        allow(attachment.file.blob).to receive(:content_type).and_return('text/html')
        expect(service.send(:image_source, attachment)).to be_nil
      end
    end

    context 'when attachment has no URL or file' do
      before do
        attachment.update(external_url: nil)
        allow(attachment).to receive(:file).and_return(instance_double(ActiveStorage::Attached::One, attached?: false))
      end

      it 'returns nil' do
        expect(service.send(:image_source, attachment)).to be_nil
      end
    end
  end

  describe '#extract_audio_transcriptions' do
    let(:message) { create(:message, content: nil) }

    context 'with no audio attachments' do
      it 'returns empty string' do
        result = service.send(:extract_audio_transcriptions, message.attachments)
        expect(result).to eq('')
      end
    end

    context 'with successful audio transcriptions' do
      let(:audio1) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :audio)
        attachment.save!
        attachment
      end

      let(:audio2) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :audio)
        attachment.save!
        attachment
      end

      before do
        message.account.update!(audio_transcriptions: true)
      end

      it 'concatenates all stored transcriptions without transcribing synchronously' do
        audio1 # trigger creation
        audio2 # trigger creation
        audio1.update!(meta: { 'transcribed_text' => 'First audio text. ' })
        audio2.update!(meta: { 'transcribed_text' => 'Second audio text.' })

        expect(Messages::AudioTranscriptionService).not_to receive(:new)

        attachments = message.attachments
        result = service.send(:extract_audio_transcriptions, attachments)
        expect(result).to eq('First audio text. Second audio text.')
      end
    end

    context 'with failed audio transcriptions' do
      let(:audio_attachment) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :audio)
        attachment.save!
        attachment
      end

      before do
        message.account.update!(audio_transcriptions: true)
      end

      it 'returns empty string when transcription is not stored yet' do
        audio_attachment # trigger creation

        expect(Messages::AudioTranscriptionService).not_to receive(:new)

        attachments = message.attachments
        result = service.send(:extract_audio_transcriptions, attachments)
        expect(result).to eq('')
      end
    end

    context 'when workspace audio transcription is disabled' do
      let(:audio_attachment) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :audio, meta: { 'transcribed_text' => 'Hidden audio text' })
        attachment.save!
        attachment
      end

      before do
        message.account.update!(audio_transcriptions: false)
      end

      it 'does not include stored audio transcription text' do
        audio_attachment # trigger creation

        expect(Messages::AudioTranscriptionService).not_to receive(:new)

        result = service.send(:extract_audio_transcriptions, message.attachments)
        expect(result).to eq('')
      end
    end
  end

  describe 'private helper methods' do
    describe '#text_part' do
      it 'returns correct text part format' do
        result = service.send(:text_part, 'Hello world')
        expect(result).to eq({ type: 'text', text: 'Hello world' })
      end
    end

    describe '#image_description_part' do
      let(:attachment) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :image, external_url: 'https://example.com/image.jpg')
        attachment.save!
        attachment
      end

      it 'returns recognized image text part format' do
        result = service.send(:image_description_part, attachment)
        expect(result).to eq({ type: 'text', text: 'Image attachment: Recognized image content' })
      end
    end
  end
end
