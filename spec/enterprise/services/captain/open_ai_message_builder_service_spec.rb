require 'rails_helper'

RSpec.describe Captain::OpenAiMessageBuilderService do
  subject(:service) { described_class.new(message: message) }

  let(:message) { create(:message, content: 'Hello world') }
  let(:image_recognition_service) { instance_double(Captain::ImageRecognitionService, perform: 'Recognized image content') }

  before do
    allow(Captain::ImageRecognitionService).to receive(:new).and_return(image_recognition_service)
  end

  # What an agent reads for an image: the text of the image said to be automatic, never the image or a link to it.
  def described(text = 'Recognized image content')
    { type: 'text', text: "Image attachment (automatic description, it may be inaccurate): #{text}" }
  end

  def image_parts_in(content)
    Array(content).select { |part| part.is_a?(Hash) && part[:type] == 'image_url' }
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

    context 'when message is a voice_call with a call recording transcript' do
      let(:message) do
        create(
          :message,
          content: 'Voice Call',
          content_type: :voice_call,
          content_attributes: {
            'data' => {
              'status' => 'completed',
              'transcript' => "Оператор: Здравствуйте, клиника OneLink\nКлиент: Запишите меня на приём завтра в 15:00"
            }
          }
        )
      end

      it 'includes the phone call transcript so Captain knows what the manager and patient discussed' do
        expect(service.generate_content).to include(
          'Voice Call',
          'Phone call transcript (Оператор = clinic manager, Клиент = patient):',
          'Оператор: Здравствуйте, клиника OneLink',
          'Клиент: Запишите меня на приём завтра в 15:00'
        )
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
        expect(result).to include(described)
        expect(image_parts_in(result)).to be_empty
      end

      it 'carries no link to the image anywhere' do
        expect(service.generate_content.to_json).not_to include('example.com')
      end
    end

    context 'when message has only non-text attachments' do
      let(:message) { create(:message, content: nil) }

      before do
        attachment = message.attachments.build(account_id: message.account_id, file_type: :image, external_url: 'https://example.com/image.jpg')
        attachment.save!
      end

      it 'returns the recognized image text only, as text, without the image' do
        expect(service.generate_content).to eq(described[:text])
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

      it 'includes the image text and no image part' do
        result = service.send(:attachment_parts, attachments)
        expect(result).to eq([described])
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

      it 'omits stored transcription when the workspace AI voice understanding is disabled' do
        # Voice understanding is a workspace-level AI setting (understanding.voice_messages) shared by every agent.
        Captain::AccountSettings.new(message.account).update!('understanding' => { 'voice_messages' => false })
        assistant = create(:captain_assistant, account: message.account)
        audio_attachment.update!(meta: { 'transcribed_text' => 'Hidden from this agent' })

        result = described_class.new(message: message, assistant: assistant).send(:attachment_parts, attachments)

        expect(result).not_to include({ type: 'text', text: 'Hidden from this agent' })
      end

      it 'ignores a legacy per-agent audio flag and follows the workspace setting' do
        assistant = create(:captain_assistant, account: message.account, config: { 'use_audio_transcriptions' => false })
        audio_attachment.update!(meta: { 'transcribed_text' => 'Visible to this agent' })

        result = described_class.new(message: message, assistant: assistant).send(:attachment_parts, attachments)

        expect(result).to include({ type: 'text', text: 'Visible to this agent' })
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
        message.account.enable_features('captain_integration')
        message.account.update!(captain_runtime: { 'web_document_parse_enabled' => true })
      end

      it 'includes stored document text instead of a generic attachment placeholder' do
        document_attachment.update!(meta: { 'parsed_text' => 'Contract terms text' })

        result = service.send(:attachment_parts, attachments)

        expect(result).to include(
          { type: 'text', text: "Document attachment: contract.pdf\nContract terms text" }
        )
        expect(result).not_to include({ type: 'text', text: 'User has shared an attachment' })
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
        expect(image_parts_in(result)).to be_empty
        expect(result).to include(described)
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

      it 'returns the text of every valid image and no image part' do
        image1 # trigger creation
        image2 # trigger creation

        image_attachments = message.attachments.where(file_type: :image)
        result = service.send(:image_parts, image_attachments)

        expect(image_parts_in(result)).to be_empty
        expect(result.count(described)).to eq(2)
      end
    end

    it 'uses the account image setting even when an agent has an old disabled value' do
      message.attachments.create!(
        account: message.account,
        file_type: :image,
        external_url: 'https://example.com/image.jpg'
      )
      image_attachments = message.attachments.where(file_type: :image)
      legacy_assistant = build(:captain_assistant, account: message.account, config: {})
      disabled_assistant = build(
        :captain_assistant,
        account: message.account,
        config: { 'feature_image_understanding' => false }
      )

      legacy_result = described_class.new(message: message, assistant: legacy_assistant)
                                     .send(:image_parts, image_attachments)
      disabled_result = described_class.new(message: message, assistant: disabled_assistant)
                                       .send(:image_parts, image_attachments)

      expect(legacy_result).to eq([described])
      expect(disabled_result).to eq([described])
    end

    context 'with sticker or gif image attachments' do
      it 'replaces sticker attachment with a text note and does not pass image_url' do
        message.update!(content_type: 'sticker')
        message.attachments.create!(
          account: message.account,
          file_type: :image,
          external_url: 'https://lookaside.fbsbx.com/ig_messaging_cdn/?asset_id=123'
        )

        result = service.send(:image_parts, message.attachments.where(file_type: :image))

        expect(result).to eq([{ type: 'text', text: 'User shared a sticker' }])
      end

      it 'does not describe a purged image attachment by a new call: its expired URL is not used' do
        message.attachments.create!(
          account: message.account,
          file_type: :image,
          external_url: 'https://lookaside.fbsbx.com/ig_messaging_cdn/?asset_id=expired',
          meta: { 'file_purged' => true }
        )

        result = service.send(:image_parts, message.attachments.where(file_type: :image))

        expect(result).to eq([])
        expect(Captain::ImageRecognitionService).not_to have_received(:new)
      end

      it 'still tells what a purged image showed when its description was kept' do
        message.attachments.create!(
          account: message.account,
          file_type: :image,
          external_url: 'https://lookaside.fbsbx.com/ig_messaging_cdn/?asset_id=expired',
          meta: { 'file_purged' => true, 'image_recognition_description' => 'Квитанция на 12 000' }
        )

        result = service.send(:image_parts, message.attachments.where(file_type: :image))

        expect(result).to eq([described('Квитанция на 12 000')])
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

    describe '#image_text_part' do
      it 'says that the text of an image is an automatic description that may be inaccurate' do
        expect(service.send(:image_text_part, 'Recognized image content')).to eq(described)
      end

      it 'leaves the plain note of an unavailable recognition as it is: it describes nothing' do
        note = Captain::ImageRecognitionService::FALLBACK_DESCRIPTION

        expect(service.send(:image_text_part, note)).to eq({ type: 'text', text: "Image attachment: #{note}" })
      end

      it 'has nothing to say about an empty description' do
        expect(service.send(:image_text_part, '  ')).to be_nil
      end
    end
  end

  describe 'a live run: no map made beforehand' do
    let(:message) { create(:message, content: 'Вот снимки') }
    let(:attachments) do
      %w[a b c].map do |name|
        message.attachments.create!(account_id: message.account_id, file_type: :image, external_url: "https://example.com/#{name}.jpg")
      end
    end

    it 'uses the description kept on the attachment and calls nobody' do
      attachments.each { |attachment| attachment.update!(meta: { 'image_recognition_description' => "Из кеша #{attachment.id}" }) }

      content = described_class.new(message: message, budget: Captain::Conversation::HistoryBudget.new).generate_content

      expect(image_parts_in(content)).to be_empty
      attachments.each { |attachment| expect(content).to include(described("Из кеша #{attachment.id}")) }
      expect(Captain::ImageRecognitionService).not_to have_received(:new)
    end

    it 'describes an image that has no description yet, once, and sends the text' do
      attachments.first

      content = described_class.new(message: message).generate_content

      expect(Captain::ImageRecognitionService).to have_received(:new).with(
        hash_including(account: message.account, attachment: attachments.first, image_url: attachments.first.external_url)
      )
      expect(image_parts_in(content)).to be_empty
      expect(content).to include(described)
    end

    it 'limits the new calls of a run by the history budget, and costs nothing for a description that exists' do
      attachments.first.update!(meta: { 'image_recognition_description' => 'Старое' })
      attachments.second
      attachments.third
      budget = Captain::Conversation::HistoryBudget.new
      stub_const('Captain::Conversation::HistoryBudget::MAX_IMAGES', 1)

      content = described_class.new(message: message, budget: budget).generate_content

      # the first image is kept; of the two new ones the budget allows a single call
      expect(Captain::ImageRecognitionService).to have_received(:new).once
      expect(content.count { |part| part[:type] == 'text' && part[:text].start_with?('Image attachment') }).to eq(2)
      expect(image_parts_in(content)).to be_empty
    end

    context 'with long descriptions (a transcription of a page is 2-5 KB)' do
      let(:long_text) { 'я' * 2_500 } # 5,000 bytes

      before { attachments.each { |attachment| attachment.update!(meta: { 'image_recognition_description' => "#{attachment.id} #{long_text}" }) } }

      def image_texts(content)
        content.select { |part| part[:type] == 'text' && part[:text].start_with?('Image attachment') }.pluck(:text)
      end

      it 'sends them through the budget of the images: whole while it lasts, then cut and marked, then a note that the text is left out' do
        content = described_class.new(message: message, budget: Captain::Conversation::HistoryBudget.new).generate_content

        first, second, third = image_texts(content)
        expect(first).to end_with("#{attachments.first.id} #{long_text}")
        expect(second).to end_with(Captain::Conversation::HistoryBudget::IMAGE_CUT_MARK)
        expect(third).to eq(Captain::ImageReading::Prompt::IMAGE_LEFT_OUT)
      end

      it 'does not count them against the text of the conversation' do
        budget = Captain::Conversation::HistoryBudget.new

        content = described_class.new(message: message, budget: budget).generate_content

        expect(budget.include_message?(content)).to be(true)
        expect(budget.include_message?('q' * (Captain::Conversation::HistoryBudget::MAX_TEXT_BYTES - 400))).to be(true)
      end

      it 'sends them whole when there is no budget (a campaign, a reminder)' do
        content = described_class.new(message: message).generate_content

        expect(image_texts(content).size).to eq(3)
        expect(image_texts(content)).to all(end_with(long_text))
      end
    end

    it 'does not touch the network to learn the type of an image' do
      attachments.first
      stub_request(:any, /example\.com/)

      described_class.new(message: message).generate_content

      expect(a_request(:any, /example\.com/)).not_to have_been_made
    end
  end

  describe 'with image descriptions made beforehand (reply suggestion)' do
    let(:message) { create(:message, content: 'Вот снимки') }
    let(:attachments) do
      %w[a b c].map do |name|
        message.attachments.create!(account_id: message.account_id, file_type: :image, external_url: "https://example.com/#{name}.jpg")
      end
    end
    let(:descriptions) { attachments.to_h { |attachment| [attachment.id, "Описание #{attachment.id}"] } }

    describe '#describable_images' do
      it 'lists the images that get a description, with their URLs' do
        attachments
        message.attachments.create!(account_id: message.account_id, file_type: :image, external_url: 'https://media.giphy.com/x.gif')

        expect(service.describable_images.map { |attachment, url| [attachment.id, url] })
          .to match_array(attachments.map { |attachment| [attachment.id, attachment.external_url] })
      end

      it 'lists nothing when image understanding is switched off' do
        attachments
        assistant = build(:captain_assistant, account: message.account)
        allow(assistant).to receive(:account_settings).and_return(instance_double(Captain::AccountSettings, section: { 'images' => false }))

        expect(described_class.new(message: message, assistant: assistant).describable_images).to eq([])
      end
    end

    it 'describes every image from the given map and never calls image recognition itself' do
      attachments
      expect(Captain::ImageRecognitionService).not_to receive(:new)
      builder = described_class.new(message: message, image_descriptions: descriptions)

      content = builder.generate_content

      expect(image_parts_in(content)).to be_empty
      attachments.each { |attachment| expect(content).to include(described("Описание #{attachment.id}")) }
    end

    it 'does not spend the budget of images: every image keeps its description, none is sent as pixels' do
      attachments
      budget = Captain::Conversation::HistoryBudget.new
      builder = described_class.new(message: message, budget: budget, image_descriptions: descriptions)

      content = builder.generate_content

      expect(image_parts_in(content)).to be_empty
      expect(content.count { |part| part[:type] == 'text' && part[:text].start_with?('Image attachment') }).to eq(3)
    end

    it 'leaves an image without a description part when none was made' do
      attachments
      builder = described_class.new(message: message, image_descriptions: {})

      expect(builder.generate_content).to eq('Вот снимки')
    end
  end
end
