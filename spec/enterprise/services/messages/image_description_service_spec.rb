# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messages::ImageDescriptionService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:message_attributes) { {} }
  let(:message) do
    create(:message, { conversation: conversation, account: account, inbox: inbox, message_type: :incoming }.merge(message_attributes))
  end
  let(:attachment_attributes) { { external_url: 'https://example.com/photo.jpg' } }
  let(:attachment) { message.attachments.create!({ account_id: account.id, file_type: :image }.merge(attachment_attributes)) }
  let(:recognition) { instance_double(Captain::ImageRecognitionService, perform: 'Направление на анализы') }

  before do
    account.enable_features!('captain_integration')
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    allow(Captain::ImageRecognitionService).to receive(:new).and_return(recognition)
  end

  describe '.enabled_for?' do
    it 'is true for an image of a public message in an inbox that has an AI agent' do
      expect(described_class.enabled_for?(attachment)).to be(true)
    end

    it 'is true for an image the clinic sent' do
      outgoing = create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing)
      sent = outgoing.attachments.create!(account_id: account.id, file_type: :image, external_url: 'https://example.com/sent.jpg')

      expect(described_class.enabled_for?(sent)).to be(true)
    end

    it 'is false for a file that is not an image' do
      document = message.attachments.create!(account_id: account.id, file_type: :file, external_url: 'https://example.com/a.pdf')

      expect(described_class.enabled_for?(document)).to be(false)
    end

    context 'when the message is a private note' do
      let(:message_attributes) { { private: true } }

      it('is false') { expect(described_class.enabled_for?(attachment)).to be(false) }
    end

    context 'when the message comes from an imported history' do
      let(:message_attributes) { { content_attributes: { imported_history: true } } }

      it('is false') { expect(described_class.enabled_for?(attachment)).to be(false) }
    end

    context 'when the message is old' do
      let(:message_attributes) { { created_at: 7.hours.ago } }

      it('is false') { expect(described_class.enabled_for?(attachment)).to be(false) }
    end

    it 'is false for an inbox without an AI agent' do
      other_inbox = create(:inbox, account: account)
      other_inbox.captain_inbox&.destroy!
      other_inbox.reload
      other_conversation = create(:conversation, account: account, inbox: other_inbox)
      other_message = create(:message, conversation: other_conversation, account: account, inbox: other_inbox)
      image = other_message.attachments.create!(account_id: account.id, file_type: :image, external_url: 'https://example.com/photo.jpg')

      expect(described_class.enabled_for?(image)).to be(false)
    end

    it 'is false when the agent of the inbox is switched off' do
      assistant.update_columns(active: false) # rubocop:disable Rails/SkipsModelValidations

      expect(described_class.enabled_for?(attachment)).to be(false)
    end

    it 'is false when the account has no AI agents' do
      account.disable_features!('captain_integration')

      expect(described_class.enabled_for?(attachment)).to be(false)
    end

    it 'is false when the understanding of images is off' do
      Captain::AccountSettings.new(account).update!('understanding' => { 'images' => false })

      expect(described_class.enabled_for?(attachment)).to be(false)
    end

    it 'is false when the AI quota of the account is used up' do
      allow(attachment.message.account).to receive(:captain_quota_available?).and_return(false)

      expect(described_class.enabled_for?(attachment)).to be(false)
    end

    it 'is false with the switch off, and true again with it on' do
      with_modified_env(described_class::SWITCH => 'off') { expect(described_class.enabled_for?(attachment)).to be(false) }
      with_modified_env(described_class::SWITCH => 'on') { expect(described_class.enabled_for?(attachment)).to be(true) }
    end
  end

  describe '#perform' do
    it 'describes the image from its URL for the account of the message' do
      described_class.new(attachment).perform

      expect(Captain::ImageRecognitionService).to have_received(:new)
        .with(account: account, attachment: attachment, image_url: 'https://example.com/photo.jpg')
      expect(recognition).to have_received(:perform)
    end

    it 'does nothing when an agent could not read the image' do
      account.disable_features!('captain_integration')

      described_class.new(attachment).perform

      expect(Captain::ImageRecognitionService).not_to have_received(:new)
    end

    it 'leaves a sticker alone' do
      sticker = message.attachments.create!(account_id: account.id, file_type: :image, external_url: 'https://example.com/s.jpg',
                                            meta: { is_sticker: true })

      described_class.new(sticker).perform

      expect(Captain::ImageRecognitionService).not_to have_received(:new)
    end

    context 'when the file is not attached yet' do
      let(:attachment_attributes) { {} }

      it 'asks for another try later' do
        expect { described_class.new(attachment).perform }.to raise_error(described_class::NotReady)
        expect(Captain::ImageRecognitionService).not_to have_received(:new)
      end

      it 'describes the image once the file is there' do
        attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')

        described_class.new(attachment).perform

        expect(Captain::ImageRecognitionService).to have_received(:new).with(hash_including(account: account, attachment: attachment))
      end
    end

    # The record is saved before its upload ends: a reading then fails on the missing file and the failure would be written against
    # the image. The job waits for the bytes instead (it retries on NotReady).
    context 'when the file is attached but its bytes are not in the storage yet' do
      let(:attachment_attributes) { {} }

      before do
        attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
      end

      it 'asks for another try later and reads nothing' do
        allow(attachment.file.blob.service).to receive(:exist?).with(attachment.file.blob.key).and_return(false)

        expect { described_class.new(attachment).perform }.to raise_error(described_class::NotReady, /not in the storage/)
        expect(Captain::ImageRecognitionService).not_to have_received(:new)
      end

      it 'reads the image once the bytes are there' do
        described_class.new(attachment).perform

        expect(recognition).to have_received(:perform)
      end
    end
  end
end
