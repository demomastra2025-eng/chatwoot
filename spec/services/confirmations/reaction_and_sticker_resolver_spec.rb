require 'rails_helper'

RSpec.describe 'Reactions, Emojis, Stickers and Image Confirmations' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let!(:resource) { create(:scheduling_resource, account: account, name: 'Д-р Смагулов') }
  let!(:appointment) do
    create(:scheduling_appointment,
           account: account,
           contact: contact,
           conversation: conversation,
           resource: resource,
           status: 'scheduled',
           starts_at: 4.hours.from_now,
           ends_at: 5.hours.from_now)
  end
  let!(:delivery_message) do
    create(:message,
           account: account,
           inbox: inbox,
           conversation: conversation,
           message_type: :outgoing,
           content: 'Напоминаем о приеме завтра в 15:00. Подтвердите, пожалуйста, визит.')
  end
  let!(:confirmation_request) do
    create(
      :confirmation_request,
      account: account,
      conversation: conversation,
      inbox: inbox,
      contact: contact,
      delivery_message: delivery_message
    )
  end

  describe '1. Emoji message replies (👍, ✅, 👌, ❌)' do
    it 'confirms the appointment immediately when the patient sends 👍 or ✅' do
      msg = create(:message, account: account, inbox: inbox, conversation: conversation,
                             message_type: :incoming, content: '👍')

      res = Confirmations::InboundTextResolver.new(
        account: account,
        conversation: conversation,
        message: msg
      ).perform

      expect(res[:handled]).to be(true)
      expect(res[:decision]).to eq('confirmed')
      expect(confirmation_request.reload.status).to eq('confirmed')
    end

    it 'declines the confirmation when the patient sends ❌ or 👎' do
      msg = create(:message, account: account, inbox: inbox, conversation: conversation,
                             message_type: :incoming, content: '👎')

      res = Confirmations::InboundTextResolver.new(
        account: account,
        conversation: conversation,
        message: msg
      ).perform

      expect(res[:handled]).to be(true)
      expect(res[:decision]).to eq('declined')
      expect(confirmation_request.reload.status).to eq('declined')
    end
  end

  describe '2. Messenger reactions (👍 / ✅) placed directly on the reminder message' do
    it 'confirms the pending ConfirmationRequest when the customer reacts with 👍 or ✅' do
      res = Confirmations::ReactionResolver.new(
        target_message: delivery_message,
        emoji: '✅'
      ).perform

      expect(res[:handled]).to be(true)
      expect(res[:decision]).to eq('confirmed')
      expect(confirmation_request.reload.status).to eq('confirmed')
      expect(confirmation_request.resolution_metadata['resolver']).to eq('reaction_emoji')
      expect(confirmation_request.resolution_metadata['emoji']).to eq('✅')
    end

    it 'auto-confirms a scheduled appointment when reacted with 👍 even without a ConfirmationRequest record' do
      confirmation_request.destroy!

      res = Confirmations::ReactionResolver.new(
        target_message: delivery_message,
        emoji: '👍🏻'
      ).perform

      expect(res[:handled]).to be(true)
      expect(res[:auto_confirmed_appointment]).to be(true)
      expect(appointment.reload.status).to eq('confirmed')
    end
  end

  describe '3. Sticker or Image with text "Окей" / thumbs-up gesture' do
    it 'extracts sticker emoji metadata and confirms the appointment' do
      sticker_msg = create(:message,
                           account: account,
                           inbox: inbox,
                           conversation: conversation,
                           message_type: :incoming,
                           content: nil,
                           content_attributes: { 'sticker_emoji' => '👌' })

      res = Confirmations::InboundTextResolver.new(
        account: account,
        conversation: conversation,
        message: sticker_msg
      ).perform

      expect(res[:handled]).to be(true)
      expect(res[:decision]).to eq('confirmed')
      expect(confirmation_request.reload.status).to eq('confirmed')
    end

    it 'recognizes text "Окей" on an attached image/sticker via ImageRecognitionService and confirms the appointment' do
      image_msg = create(:message,
                         account: account,
                         inbox: inbox,
                         conversation: conversation,
                         message_type: :incoming,
                         content: nil)
      attachment = image_msg.attachments.create!(
        account_id: account.id,
        file_type: :image,
        external_url: 'https://example.com/sticker-okay.webp'
      )

      recognizer_double = instance_double(
        Captain::ImageRecognitionService,
        perform: 'Стикер с поднятым вверх большим пальцем и надписью "Окей"'
      )
      expect(Captain::ImageRecognitionService).to receive(:new).with(
        hash_including(account: account, attachment: attachment)
      ).and_return(recognizer_double)

      res = Confirmations::InboundTextResolver.new(
        account: account,
        conversation: conversation,
        message: image_msg.reload
      ).perform

      expect(res[:handled]).to be(true)
      expect(res[:decision]).to eq('confirmed')
      expect(confirmation_request.reload.status).to eq('confirmed')
    end
  end

  describe "4. Four appointments on the same day: 'Ок' vs 'Я не приду'" do
    let!(:apt2) do
      create(:scheduling_appointment, account: account, contact: contact, conversation: conversation,
                                      resource: resource, status: 'scheduled', starts_at: 5.hours.from_now, ends_at: 6.hours.from_now)
    end
    let!(:apt3) do
      create(:scheduling_appointment, account: account, contact: contact, conversation: conversation,
                                      resource: resource, status: 'scheduled', starts_at: 6.hours.from_now, ends_at: 7.hours.from_now)
    end
    let!(:apt4) do
      create(:scheduling_appointment, account: account, contact: contact, conversation: conversation,
                                      resource: resource, status: 'scheduled', starts_at: 7.hours.from_now, ends_at: 8.hours.from_now)
    end

    it "confirms ALL 4 appointments on the same day when the customer replies 'Ок'" do
      msg = create(:message, account: account, inbox: inbox, conversation: conversation,
                             message_type: :incoming, content: 'Ок')

      res = Confirmations::InboundTextResolver.new(
        account: account,
        conversation: conversation,
        message: msg
      ).perform

      expect(res[:handled]).to be(true)
      expect(res[:decision]).to eq('confirmed')
      expect([appointment, apt2, apt3, apt4].map { |a| a.reload.status }).to eq(%w[confirmed confirmed confirmed confirmed])
    end

    it "does NOT silently cancel just one appointment when there are 4 appointments and the customer says 'Я не приду'" do
      msg = create(:message, account: account, inbox: inbox, conversation: conversation,
                             message_type: :incoming, content: 'Я не приду')

      res = Confirmations::InboundTextResolver.new(
        account: account,
        conversation: conversation,
        message: msg
      ).perform

      expect(res[:handled]).to be(false)
      expect(res[:reason]).to eq('multiple_upcoming_appointments')
      expect(confirmation_request.reload.status).to eq('pending')
      expect([appointment, apt2, apt3, apt4].map { |a| a.reload.status }).to eq(%w[scheduled scheduled scheduled scheduled])
    end
  end
end
