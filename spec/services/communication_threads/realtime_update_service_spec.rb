require 'rails_helper'

RSpec.describe CommunicationThreads::RealtimeUpdateService do
  describe '#perform' do
    def expect_hidden_recipient_excluded(members, payload, hidden_user:, hidden_conversation:)
      expect(members).not_to include(hidden_user.pubsub_token)
      expect(payload[:conversation_ids]).not_to include(hidden_conversation.display_id)
    end

    it 'broadcasts the same shared unread state to each authorized operator' do
      account = create(:account).tap { |record| record.enable_features!('communication_threads') }
      inbox = create(:inbox, account: account)
      first_user = create(:user, account: account, role: :agent)
      second_user = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: inbox, user: first_user)
      create(:inbox_member, inbox: inbox, user: second_user)
      conversation = create(:conversation, account: account, inbox: inbox, agent_last_seen_at: 1.hour.ago)
      message = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        created_at: 5.minutes.ago
      )
      create(
        :conversation_user_read_state,
        account: account,
        conversation: conversation,
        user: first_user,
        last_seen_at: Time.current
      )
      create(
        :conversation_user_read_state,
        account: account,
        conversation: conversation,
        user: second_user,
        last_seen_at: 1.hour.ago
      )
      broadcasts = []
      allow(ActionCableBroadcastJob).to receive(:perform_later) { |members, event, payload| broadcasts << [members, event, payload] }
      expect(Scheduling::AppointmentDialogStatusContextBuilder).to receive(:new).once.and_call_original

      described_class.new(
        communication_thread_id: conversation.reload.communication_thread.id,
        source_conversation_id: conversation.id,
        source_event: 'message.created',
        message_id: message.id
      ).perform

      thread_broadcasts = broadcasts.select { |_members, event, _payload| event == 'communication_thread.updated' }
      expect(thread_broadcasts.size).to eq(1)
      members, _event, payload = thread_broadcasts.first
      expect(members).to contain_exactly(first_user.pubsub_token, second_user.pubsub_token)
      expect(payload).to include(unread_count: 1)
      expect(payload.fetch(:channels).first).to include(unread_count: 1)
    end

    it 'does not broadcast a source conversation hidden by a custom role' do
      account = create(:account).tap { |record| record.enable_features!('communication_threads') }
      inbox = create(:inbox, account: account)
      custom_role = create(:custom_role, account: account, permissions: [])
      restricted_user = create(:user, account: account, role: :agent)
      restricted_user.account_users.find_by(account: account).update!(custom_role: custom_role)
      create(:inbox_member, inbox: inbox, user: restricted_user)
      conversation = create(:conversation, account: account, inbox: inbox)
      broadcasts = []
      allow(ActionCableBroadcastJob).to receive(:perform_later) { |members, event, payload| broadcasts << [members, event, payload] }

      described_class.new(
        communication_thread_id: conversation.reload.communication_thread.id,
        source_conversation_id: conversation.id,
        source_event: 'conversation.updated'
      ).perform

      expect(broadcasts.none? { |members, _event, _payload| members.include?(restricted_user.pubsub_token) }).to be(true)
    end

    it 'broadcasts to authorized team members with only their visible linked channels' do
      account = create(:account).tap { |record| record.enable_features!('communication_threads') }
      contact = create(:contact, account: account)
      source_inbox = create(:inbox, account: account)
      hidden_inbox = create(:inbox, account: account)
      source_team = create(:team, account: account)
      hidden_team = create(:team, account: account)
      team_user = create(:user, account: account, role: :agent)
      hidden_inbox_user = create(:user, account: account, role: :agent)
      create(:team_member, team: source_team, user: team_user)
      create(:inbox_member, inbox: hidden_inbox, user: hidden_inbox_user)
      [source_inbox, hidden_inbox].each do |target_inbox|
        target_inbox.inbox_members.where(user: team_user).destroy_all
      end
      source_inbox.inbox_members.where(user: hidden_inbox_user).destroy_all

      source_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: source_inbox,
        team: source_team
      )
      hidden_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: hidden_inbox,
        team: hidden_team
      )
      thread = source_conversation.reload.communication_thread
      expect(hidden_conversation.reload.communication_thread).to eq(thread)
      expect(team_user.inboxes).not_to include(source_inbox)
      user_context = {
        user: team_user,
        account: account,
        account_user: team_user.account_users.find_by!(account: account)
      }
      expect(ConversationPolicy.new(user_context, source_conversation).show?).to be(true)

      broadcasts = []
      allow(ActionCableBroadcastJob).to receive(:perform_later) { |members, event, payload| broadcasts << [members, event, payload] }

      described_class.new(
        communication_thread_id: thread.id,
        source_conversation_id: source_conversation.id,
        source_event: 'conversation.read'
      ).perform

      thread_broadcasts = broadcasts.select { |_members, event, _payload| event == 'communication_thread.updated' }
      expect(thread_broadcasts.size).to eq(1)
      members, _event, payload = thread_broadcasts.first
      expect(members).to contain_exactly(team_user.pubsub_token)
      expect(payload[:conversation_ids]).to contain_exactly(source_conversation.display_id)
      channel_conversation_ids = payload.fetch(:channels).map { |channel| channel[:conversation_id] }
      expect(channel_conversation_ids).to contain_exactly(source_conversation.display_id)
      expect_hidden_recipient_excluded(
        members, payload, hidden_user: hidden_inbox_user, hidden_conversation: hidden_conversation
      )
    end

    context 'when one person is reachable on two channels' do
      let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:contact) { create(:contact, :with_avatar, account: account, name: 'Arman') }
      let(:telegram_inbox) { create(:inbox, account: account) }
      let(:whatsapp_inbox) { create(:inbox, account: account) }
      let(:telegram_contact_inbox) { create(:contact_inbox, contact: contact, inbox: telegram_inbox) }
      let(:whatsapp_contact_inbox) { create(:contact_inbox, contact: contact, inbox: whatsapp_inbox) }
      let(:telegram_conversation) do
        create(:conversation, account: account, contact: contact, inbox: telegram_inbox, contact_inbox: telegram_contact_inbox)
      end
      let(:whatsapp_conversation) do
        create(:conversation, account: account, contact: contact, inbox: whatsapp_inbox, contact_inbox: whatsapp_contact_inbox)
      end
      let(:broadcasts) { [] }

      before do
        create(:inbox_member, inbox: telegram_inbox, user: agent)
        create(:inbox_member, inbox: whatsapp_inbox, user: agent)
        create(
          :contact_channel_profile,
          contact: contact, contact_inbox: telegram_contact_inbox, inbox: telegram_inbox,
          provider: 'telegram_personal',
          display_name: 'Arman Telegram', avatar_url: 'https://cdn.example.com/tg-avatar.jpg'
        )
        create(
          :contact_channel_profile,
          contact: contact, contact_inbox: whatsapp_contact_inbox, inbox: whatsapp_inbox,
          provider: 'whatsapp_web',
          display_name: 'Akhan WhatsApp', avatar_url: nil
        )
        telegram_conversation
        whatsapp_conversation
        allow(ActionCableBroadcastJob).to receive(:perform_later) { |members, event, payload| broadcasts << [members, event, payload] }
      end

      def thread_payload_for(conversation)
        broadcasts.clear
        described_class.new(
          communication_thread_id: telegram_conversation.reload.communication_thread.id,
          source_conversation_id: conversation.id,
          source_event: 'message.created'
        ).perform
        broadcasts.find { |_members, event, _payload| event == 'communication_thread.updated' }.last
      end

      it 'sends the same name and avatar from a Telegram event and from a WhatsApp event' do
        expect(whatsapp_conversation.reload.communication_thread).to eq(telegram_conversation.reload.communication_thread)

        from_telegram = thread_payload_for(telegram_conversation)
        from_whatsapp = thread_payload_for(whatsapp_conversation)

        expect(from_telegram[:contact_inbox_id]).not_to eq(from_whatsapp[:contact_inbox_id])
        telegram_sender = from_telegram.dig(:meta, :sender)
        whatsapp_sender = from_whatsapp.dig(:meta, :sender)
        expect(telegram_sender.slice(:id, :name, :thumbnail)).to eq(whatsapp_sender.slice(:id, :name, :thumbnail))
        expect(telegram_sender[:name]).to eq('Arman')
        expect(telegram_sender[:thumbnail]).to eq(contact.reload.resolved_avatar_url)
        expect(telegram_sender[:thumbnail]).to eq(contact.contact_avatar_url)
        expect(telegram_sender[:thumbnail]).to be_present
      end

      it 'keeps each channel profile in channels instead of the person sender' do
        payload = thread_payload_for(telegram_conversation)

        expect(payload.dig(:meta, :sender)).not_to have_key(:channel_profile)
        profiles = payload.fetch(:channels).to_h { |channel| [channel[:contact_inbox_id], channel[:channel_profile]] }
        expect(profiles.fetch(telegram_contact_inbox.id)).to include(display_name: 'Arman Telegram')
        expect(profiles.fetch(whatsapp_contact_inbox.id)).to include(display_name: 'Akhan WhatsApp')
      end

      it 'keeps the chosen avatar source for events from either channel' do
        contact.update!(
          additional_attributes: contact.merge_display_source(
            additional_attributes: contact.additional_attributes,
            key: Contact::PRIMARY_AVATAR_SOURCE_KEY,
            source: contact.display_source_for_contact_inbox(telegram_contact_inbox)
          )
        )

        thumbnails = [telegram_conversation, whatsapp_conversation].map do |conversation|
          thread_payload_for(conversation).dig(:meta, :sender, :thumbnail)
        end

        expect(thumbnails).to eq(['https://cdn.example.com/tg-avatar.jpg'] * 2)
      end
    end
  end
end
