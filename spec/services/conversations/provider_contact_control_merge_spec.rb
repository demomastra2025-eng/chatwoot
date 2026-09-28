require 'rails_helper'

RSpec.describe 'provider contact merges preserve Captain control' do # rubocop:disable RSpec/DescribeClass
  %i[telegram whatsapp_web].each do |provider|
    it "preserves source human takeover and links on #{provider} phone conflict with two Threads" do # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
      account = create(:account)
      channel = if provider == :telegram
                  create(:channel_telegram_personal, account: account, phone_number: '+77066318623')
                else
                  create(:channel_whatsapp_web, account: account)
                end
      source_profiles = { provider.to_s => { '23' => { 'name' => 'Source' } } }
      source = create(:contact, account: account, identifier: "#{provider}:23",
                                additional_attributes: { 'provider' => provider.to_s, 'channel_profiles' => source_profiles })
      target_profiles = { 'other' => { 'x' => { 'name' => 'Target' } } }
      target = create(:contact, account: account, phone_number: '+15551234567',
                                additional_attributes: { 'provider' => 'other', 'channel_profiles' => target_profiles })
      original_phone = target.phone_number
      source_inbox = create(:contact_inbox, contact: source, inbox: channel.inbox, source_id: '23')
      captain_inbox = create(:inbox, account: account)
      target_inbox = create(:contact_inbox, contact: target, inbox: captain_inbox)
      assistant = create(:captain_assistant, account: account)
      create(:captain_inbox, inbox: captain_inbox, captain_assistant: assistant)
      source_conversation = create(:conversation, account: account, contact: source, inbox: channel.inbox, contact_inbox: source_inbox)
      target_conversation = create(:conversation, account: account, contact: target, inbox: captain_inbox,
                                                  contact_inbox: target_inbox, status: :pending)
      source_thread = create(:communication_thread, account: account, contact: source,
                                                    captain_control_state: 'human', captain_control_generation: 3,
                                                    captain_handoff_applied_at: 1.hour.ago)
      target_thread = create(:communication_thread, account: account, contact: target,
                                                    captain_control_state: 'ai', captain_control_generation: 2)
      create(:communication_thread_conversation, account: account, conversation: source_conversation,
                                                 communication_thread: source_thread)
      create(:communication_thread_conversation, account: account, conversation: target_conversation,
                                                 communication_thread: target_thread)
      owner = create(:user, account: account)
      source.update!(owner: owner)
      incoming = create(:message, account: account, conversation: target_conversation, inbox: captain_inbox,
                                  sender: target, message_type: :incoming)
      queued = create(:message, account: account, conversation: target_conversation, inbox: captain_inbox,
                                sender: assistant, message_type: :outgoing,
                                additional_attributes: { captain_delivery_fence: {
                                  control_generation: 2, assistant_id: assistant.id,
                                  trigger_message_id: incoming.id, kind: 'reply'
                                } })
      provider_service = if provider == :telegram
                           TelegramPersonal::ContactSyncService.new(inbox: channel.inbox,
                                                                    params: { peer_user_id: '23', phone_number: '15551234567' })
                         else
                           WhatsappWeb::ContactSyncService.new(channel: channel,
                                                               contact_payload: { remoteJid: '15551234567@s.whatsapp.net' })
                         end
      provider_service.instance_variable_set(:@contact, source) if provider == :telegram
      provider_service.instance_variable_set(:@contact_inbox, source_inbox)
      if provider == :telegram
        provider_service.send(:merge_phone_contact!)
      else
        provider_service.send(:merge_phone_contact!, source_contact: source, phone_number: target.phone_number)
      end

      expect(Contact.exists?(source.id)).to be(false)
      expect(source_inbox.reload.contact_id).to eq(target.id)
      expect(source_conversation.reload.contact_id).to eq(target.id)
      expect(target.reload.owner).to eq(owner)
      expect(target.identifier).to eq("#{provider}:23")
      expect(target.phone_number).to eq(original_phone)
      expect(target.reload.additional_attributes.dig('channel_profiles', 'other', 'x', 'name')).to eq('Target')
      expect(target.additional_attributes.dig('channel_profiles', provider.to_s, '23', 'name')).to eq('Source')
      expect(CommunicationThread.where(contact_id: target.id).pluck(:id)).to eq([target_thread.id])
      expect(CommunicationThread.exists?(source_thread.id)).to be(false)
      expect(target_thread.reload).to have_attributes(captain_control_state: 'human', captain_control_generation: 4)
      expect(target_thread.captain_handoff_applied_at).to be_present
      expect(target_thread.conversations.reload.pluck(:id)).to contain_exactly(source_conversation.id, target_conversation.id)
      expect(target_conversation.reload.current_captain_control_generation).to eq(4)
      provider_sender = instance_double(Messages::SendEmailNotificationService, perform: nil)
      allow(Messages::SendEmailNotificationService).to receive(:new).and_return(provider_sender)
      expect { SendReplyJob.perform_now(queued.id) }.not_to raise_error
      expect(provider_sender).not_to have_received(:perform)
      expect(queued.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
    end
  end
end
