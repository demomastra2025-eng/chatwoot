require 'rails_helper'

RSpec.describe Captain::OpenAiMessageBuilderService do
  subject(:service) { described_class.new(message: message, assistant: assistant) }

  let(:message) { create(:message, content: 'Hello world') }
  let(:assistant) do
    create(:captain_assistant, account: message.account, config: { 'feature_document_reading' => true })
  end
  let(:image_recognition_service) { instance_double(Captain::ImageRecognitionService, perform: 'Recognized image content') }

  before do
    allow(Captain::ImageRecognitionService).to receive(:new).and_return(image_recognition_service)
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
        expect(result).to include({ type: 'image_url', image_url: { url: 'https://example.com/image.jpg' } })
        expect(result).to include({ type: 'text', text: 'Image attachment: Recognized image content' })
      end
    end

    context 'when message has only non-text attachments' do
      let(:message) { create(:message, content: nil) }

      before do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :image, external_url: 'https://example.com/image.jpg')
        attachment.save!
      end

      it 'returns image URL and recognized image text without original text' do
        result = service.generate_content
        expect(result).to eq(
          [
            { type: 'image_url', image_url: { url: 'https://example.com/image.jpg' } },
            { type: 'text', text: 'Image attachment: Recognized image content' }
          ]
        )
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
        expect(result).to include({ type: 'image_url', image_url: { url: 'https://example.com/image.jpg' } })
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
        message.account.update!(captain_features: { 'audio_transcription' => true })
      end

      it 'includes stored transcription text part without transcribing synchronously' do
        audio_attachment # trigger creation
        audio_attachment.update!(meta: { 'transcribed_text' => 'Audio transcription text' })

        expect(Messages::AudioTranscriptionService).not_to receive(:new)

        result = service.send(:attachment_parts, attachments)
        expect(result).to include({ type: 'text', text: 'Audio transcription text' })
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
        message.account.update!(captain_features: { 'audio_transcription' => true })
      end

      it 'includes all relevant parts' do
        image_attachment    # trigger creation
        audio_attachment    # trigger creation
        document_attachment # trigger creation
        audio_attachment.update!(meta: { 'transcribed_text' => 'Audio text' })

        expect(Messages::AudioTranscriptionService).not_to receive(:new)

        result = service.send(:attachment_parts, attachments)
        expect(result).to include({ type: 'image_url', image_url: { url: 'https://example.com/image.jpg' } })
        expect(result).to include({ type: 'text', text: 'Image attachment: Recognized image content' })
        expect(result).to include({ type: 'text', text: 'Audio text' })
        expect(result).to include({ type: 'text', text: 'User has shared an attachment' })
      end
    end
  end

  describe '#image_parts' do
    let(:message) { create(:message, content: nil) }

    context 'with valid image attachments' do
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

      it 'returns image parts for all valid images' do
        image1 # trigger creation
        image2 # trigger creation

        image_attachments = message.attachments.where(file_type: :image)
        result = service.send(:image_parts, image_attachments)

        expect(result).to include({ type: 'image_url', image_url: { url: 'https://example.com/image1.jpg' } })
        expect(result).to include({ type: 'image_url', image_url: { url: 'https://example.com/image2.jpg' } })
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

      it 'skips images without valid URLs' do
        image_attachment # trigger creation

        image_attachments = message.attachments.where(file_type: :image)
        result = service.send(:image_parts, image_attachments)

        expect(result).to be_empty
      end
    end
  end

  describe '#get_attachment_url' do
    let(:attachment) do
      attachment = message.attachments.build(account_id: message.account_id, file_type: :image)
      attachment.save!
      attachment
    end

    context 'when attachment has external_url' do
      before { attachment.update(external_url: 'https://example.com/image.jpg') }

      it 'returns external_url' do
        expect(service.send(:get_attachment_url, attachment)).to eq('https://example.com/image.jpg')
      end
    end

    context 'when attachment has attached file' do
      before do
        attachment.update(external_url: nil)
        allow(attachment).to receive(:file).and_return(instance_double(ActiveStorage::Attached::One, attached?: true))
        allow(attachment).to receive(:file_url).and_return('https://local.com/file.jpg')
        allow(attachment).to receive(:download_url).and_return('')
      end

      it 'returns file_url' do
        expect(service.send(:get_attachment_url, attachment)).to eq('https://local.com/file.jpg')
      end
    end

    context 'when attachment has no URL or file' do
      before do
        attachment.update(external_url: nil)
        allow(attachment).to receive(:file).and_return(instance_double(ActiveStorage::Attached::One, attached?: false))
      end

      it 'returns nil' do
        expect(service.send(:get_attachment_url, attachment)).to be_nil
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
        message.account.update!(captain_features: { 'audio_transcription' => true })
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
        message.account.update!(captain_features: { 'audio_transcription' => true })
      end

      it 'returns empty string when transcription is not stored yet' do
        audio_attachment # trigger creation

        expect(Messages::AudioTranscriptionService).not_to receive(:new)

        attachments = message.attachments
        result = service.send(:extract_audio_transcriptions, attachments)
        expect(result).to eq('')
      end
    end

    context 'when captain audio transcription feature is disabled' do
      let(:audio_attachment) do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :audio, meta: { 'transcribed_text' => 'Hidden audio text' })
        attachment.save!
        attachment
      end

      before do
        message.account.update!(captain_features: { 'audio_transcription' => false })
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
        result = service.send(:image_description_part, attachment, 'https://example.com/image.jpg')
        expect(result).to eq({ type: 'text', text: 'Image attachment: Recognized image content' })
      end
    end
  end
end
