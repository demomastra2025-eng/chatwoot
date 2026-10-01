require 'rails_helper'

# sc8rv2 T3 (M6): an agent's follow-up scheduled in the chat of the number (remindable = that conversation) follows the
# chat when a promotion moves it to the card, and is delivered there, on WhatsApp Web and on WhatsApp Cloud.
RSpec.describe Contacts::NumberHistoryTransferService do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) do
    create(:account, locale: 'ru', limits: { non_web_inboxes: ChatwootApp.max_limit }).tap { |record| record.enable_features!('scheduling') }
  end
  let(:phone) { SharedPhoneHelpers::FAMILY_PHONE }
  let(:digits) { phone.delete('+') }
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: '+77000000008') }

  before do
    stub_request(:any, /.*/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    # The behaviour with the capabilities switched on (they ship off, see Contacts::SharedPhoneSwitches).
    enable_shared_phone_switches!
  end

  def touch_messages(touch)
    Message.outgoing.where(account_id: account.id).where("additional_attributes ->> 'touch_id' = ?", touch.id.to_s)
  end

  %w[whatsapp_web whatsapp_cloud].each do |kind|
    it "T3 (#{kind}) delivers a pending follow-up of the moved chat in that chat, to the card", :aggregate_failures do
      inbox = kind == 'whatsapp_web' ? create(:channel_whatsapp_web, account: account).inbox : shared_phone_cloud_inbox(account)
      contact_inbox, conversation = shared_phone_chat(account, mother, inbox, digits)
      card = shared_phone_card(account, mother)
      touch = create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, status: :pending,
                                body: 'Follow-up', scheduled_at: 1.minute.ago)

      Contacts::SharedPhonePromotionService.new(card: Contact.find(card.id), basis: 'medelement').perform
      expect(Reminder.find(touch.id)).to have_attributes(target_contact_id: card.id, target_contact_inbox_id: contact_inbox.id,
                                                         target_conversation_id: conversation.id)

      Reminders::ProcessPendingRemindersJob.perform_now
      claimed = Reminder.find(touch.id)
      expect(claimed).to be_processing
      Reminders::ExecuteService.new(reminder: claimed, processing_claim: claimed.processing_claim_token).perform

      expect(Reminder.find(touch.id)).to be_completed
      delivered = touch_messages(touch).map { |message| [message.conversation_id, message.conversation.contact_id] }
      expect(delivered).to eq([[conversation.id, card.id]])
    end
  end
end
