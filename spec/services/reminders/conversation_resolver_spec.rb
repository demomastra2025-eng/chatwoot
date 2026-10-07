require 'rails_helper'

RSpec.describe Reminders::ConversationResolver do
  it 'does not execute a persisted route after the WhatsApp contact identity changes' do
    account = create(:account)
    contact = create(:contact, account: account, phone_number: '+77001232231')
    channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
    stale_contact_inbox = create(
      :contact_inbox,
      contact: contact,
      inbox: channel.inbox,
      source_id: contact.phone_number.delete('+')
    )
    stale_conversation = create(
      :conversation,
      account: account,
      inbox: channel.inbox,
      contact: contact,
      contact_inbox: stale_contact_inbox
    )
    create(:message, account: account, inbox: channel.inbox, conversation: stale_conversation, message_type: :incoming)
    reminder = create(
      :reminder,
      account: account,
      conversation: stale_conversation,
      remindable: stale_conversation,
      target_inbox: channel.inbox,
      target_contact: contact,
      target_contact_inbox: stale_contact_inbox,
      target_conversation: stale_conversation,
      status: :pending
    )
    contact.update!(phone_number: '+77001232232')
    current_contact_inbox = create(
      :contact_inbox,
      contact: contact,
      inbox: channel.inbox,
      source_id: contact.phone_number.delete('+')
    )
    current_conversation = create(
      :conversation,
      account: account,
      inbox: channel.inbox,
      contact: contact,
      contact_inbox: current_contact_inbox
    )

    resolved_conversation = described_class.new(reminder: reminder).perform

    expect(resolved_conversation).to eq(current_conversation)
  end

  describe '#perform' do
    it 'does not return an open source conversation from another inbox' do
      account = create(:account)
      source_inbox = create(:inbox, account: account)
      target_inbox = create(:inbox, account: account)
      contact = create(:contact, account: account)
      source_contact_inbox = create(:contact_inbox, contact: contact, inbox: source_inbox)
      target_contact_inbox = create(:contact_inbox, contact: contact, inbox: target_inbox)
      source_conversation = create(
        :conversation,
        account: account,
        inbox: source_inbox,
        contact: contact,
        contact_inbox: source_contact_inbox,
        status: :open
      )
      reminder = build(
        :reminder,
        account: account,
        conversation: source_conversation,
        remindable: source_conversation,
        target_inbox: target_inbox,
        target_contact: contact,
        target_contact_inbox: target_contact_inbox,
        target_conversation: nil
      )

      resolved = described_class.new(reminder: reminder).perform

      expect(resolved).not_to eq(source_conversation)
      expect(resolved).to have_attributes(
        account_id: account.id,
        inbox_id: target_inbox.id,
        contact_id: contact.id,
        contact_inbox_id: target_contact_inbox.id
      )
    end

    it 'raises a non-retryable error when the target cannot be routed to the inbox' do
      inbox = instance_double(Inbox, channel_type: 'Channel::Api')
      contact = instance_double(Contact)
      reminder = instance_double(
        Reminder,
        target_conversation: nil,
        conversation: nil,
        target_contact_inbox: nil,
        target_inbox: inbox,
        target_contact: contact
      )
      identity_resolver = instance_double(Campaigns::TargetResolver, resolve: nil)
      resolver = instance_double(Outbound::ContactInboxResolver, perform: nil)

      allow(Campaigns::TargetResolver).to receive(:new).with(inbox: inbox, contact: contact).and_return(identity_resolver)
      allow(Outbound::ContactInboxResolver).to receive(:new)
        .with(inbox: inbox, contact: contact, source_id: nil)
        .and_return(resolver)

      expect { described_class.new(reminder: reminder).perform }
        .to raise_error(Reminders::UndeliverableTargetError, 'Touch target is not deliverable for this inbox')
    end

    context 'with a Telegram contact whose conversations are all closed' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_telegram, account: account) }
      let(:inbox) { channel.inbox }
      let(:contact) { create(:contact, account: account) }
      let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '123456789') }
      let!(:inactive_conversation) do
        create(
          :conversation,
          account: account,
          inbox: inbox,
          contact: contact,
          contact_inbox: contact_inbox,
          status: :resolved,
          additional_attributes: { 'chat_id' => 111_111_111 }
        ).tap { |conversation| conversation.update_columns(created_at: 30.minutes.ago, last_activity_at: 2.hours.ago) } # rubocop:disable Rails/SkipsModelValidations
      end
      let!(:resolved_conversation) do
        create(
          :conversation,
          account: account,
          inbox: inbox,
          contact: contact,
          contact_inbox: contact_inbox,
          status: :resolved,
          additional_attributes: {
            'chat_id' => 987_654_321,
            'business_connection_id' => 'business-1'
          }
        ).tap { |conversation| conversation.update_columns(created_at: 2.days.ago, last_activity_at: 1.hour.ago) } # rubocop:disable Rails/SkipsModelValidations
      end
      let(:reminder) do
        instance_double(
          Reminder,
          account_id: account.id,
          target_conversation: nil,
          conversation: nil,
          target_contact_inbox: contact_inbox,
          target_inbox: inbox,
          target_contact: contact,
          metadata: {},
          body: 'Follow up'
        )
      end

      it 'sends into the latest closed conversation, keeping its transport attributes, when the inbox keeps one conversation per contact' do
        expect(inbox).to be_lock_to_single_conversation

        conversation = nil
        expect { conversation = described_class.new(reminder: reminder).perform }.not_to(change(Conversation, :count))

        expect(conversation).to eq(resolved_conversation)
        expect(conversation).not_to eq(inactive_conversation)
        expect(conversation.reload).to be_resolved
        expect(conversation.additional_attributes).to include(
          'chat_id' => 987_654_321,
          'business_connection_id' => 'business-1'
        )
      end

      it 'copies the transport attributes into a new closed conversation when the inbox has no single-conversation lock' do
        inbox.update!(lock_to_single_conversation: false)

        conversation = nil
        expect { conversation = described_class.new(reminder: reminder).perform }.to change(Conversation, :count).by(1)

        expect(conversation).not_to eq(resolved_conversation)
        expect(conversation).not_to eq(inactive_conversation)
        expect(conversation).to be_resolved
        expect(conversation.additional_attributes).to include(
          'chat_id' => 987_654_321,
          'business_connection_id' => 'business-1',
          'outbound_automated' => true
        )
        expect(resolved_conversation.reload).to be_resolved
      end
    end

    it 'falls back to the Telegram contact inbox source id' do
      account = create(:account)
      channel = create(:channel_telegram, account: account)
      inbox = channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '123456789')
      reminder = instance_double(
        Reminder,
        account_id: account.id,
        target_conversation: nil,
        conversation: nil,
        target_contact_inbox: contact_inbox,
        target_inbox: inbox,
        target_contact: contact,
        metadata: {},
        body: 'Follow up'
      )

      conversation = described_class.new(reminder: reminder).perform

      expect(conversation.additional_attributes['chat_id']).to eq('123456789')
    end

    it 'falls back when the latest Telegram conversation has a blank chat id' do
      account = create(:account)
      channel = create(:channel_telegram, account: account)
      inbox = channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '123456789')
      create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: :resolved,
        additional_attributes: { 'chat_id' => '' }
      )
      reminder = instance_double(
        Reminder,
        account_id: account.id,
        target_conversation: nil,
        conversation: nil,
        target_contact_inbox: contact_inbox,
        target_inbox: inbox,
        target_contact: contact,
        metadata: {},
        body: 'Follow up'
      )

      conversation = described_class.new(reminder: reminder).perform

      expect(conversation.additional_attributes['chat_id']).to eq('123456789')
    end
  end

  # An automated notification never reopens a closed conversation: it goes into the latest closed conversation when the
  # inbox keeps one conversation per contact, and otherwise into a conversation that is created closed and marked.
  describe '#perform when the contact has only closed conversations' do
    let(:account) { create(:account) }
    let(:inbox) { create(:inbox, account: account) }
    let(:contact) { create(:contact, :with_email, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

    def build_reminder(target_inbox: inbox, target_contact_inbox: contact_inbox, **overrides)
      instance_double(
        Reminder,
        {
          account_id: account.id,
          target_conversation: nil,
          conversation: nil,
          target_contact_inbox: target_contact_inbox,
          target_inbox: target_inbox,
          target_contact: target_contact_inbox.contact,
          metadata: {},
          body: 'Follow up'
        }.merge(overrides)
      )
    end

    def create_conversation(status, **attributes)
      create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: status, **attributes)
    end

    context 'when the inbox keeps one conversation per contact' do
      before { inbox.update!(lock_to_single_conversation: true) }

      it 'sends into the latest closed conversation without changing its status or creating another one' do
        create_conversation(:resolved)
        latest = create_conversation(:resolved)

        conversation = nil
        expect { conversation = described_class.new(reminder: build_reminder).perform }.not_to(change(Conversation, :count))

        expect(conversation).to eq(latest)
        expect(conversation.reload).to be_resolved
      end

      it 'prefers the latest conversation over an older closed target conversation' do
        older = create_conversation(:resolved)
        latest = create_conversation(:resolved)

        conversation = described_class.new(reminder: build_reminder(target_conversation: older)).perform

        expect(conversation).to eq(latest)
      end
    end

    context 'when the inbox has no single-conversation lock' do
      before { inbox.update!(lock_to_single_conversation: false) }

      it 'creates a conversation that is closed, marked as an automated notification and not waiting for a reply', :aggregate_failures do
        previous = create_conversation(:resolved)

        conversation = nil
        expect { conversation = described_class.new(reminder: build_reminder).perform }.to change(Conversation, :count).by(1)

        expect(conversation).not_to eq(previous)
        expect(conversation).to be_resolved
        expect(conversation.waiting_since).to be_nil
        expect(conversation.additional_attributes).to include('outbound_automated' => true)
        expect(conversation).to have_attributes(
          account_id: account.id,
          inbox_id: inbox.id,
          contact_id: contact.id,
          contact_inbox_id: contact_inbox.id
        )
        expect(conversation.status_transitions).to be_empty
        expect(previous.reload).to be_resolved
      end

      it 'sends the next notification into the same conversation instead of creating another one' do
        create_conversation(:resolved)
        first = described_class.new(reminder: build_reminder).perform

        second = nil
        expect { second = described_class.new(reminder: build_reminder).perform }.not_to(change(Conversation, :count))

        expect(second).to eq(first)
        expect(second).to be_resolved
      end

      it 'creates a new notification conversation when a person conversation is newer than the earlier one' do
        create_conversation(:resolved)
        earlier_carrier = described_class.new(reminder: build_reminder).perform
        newer_person_conversation = create_conversation(:resolved)

        conversation = described_class.new(reminder: build_reminder).perform

        expect(conversation).not_to eq(earlier_carrier)
        expect(conversation).not_to eq(newer_person_conversation)
        expect(conversation).to be_resolved
        expect(conversation.additional_attributes).to include('outbound_automated' => true)
      end

      %i[open pending snoozed].each do |status|
        it "reuses a #{status} conversation without changing its status, even when a closed one is newer" do
          active = create_conversation(status)
          create_conversation(:resolved)

          conversation = nil
          expect { conversation = described_class.new(reminder: build_reminder).perform }.not_to(change(Conversation, :count))

          expect(conversation).to eq(active)
          expect(conversation.reload.status).to eq(status.to_s)
        end
      end

      it 'creates a closed notification conversation for a contact without any conversation' do
        conversation = described_class.new(reminder: build_reminder).perform

        expect(conversation).to be_resolved
        expect(conversation.additional_attributes).to include('outbound_automated' => true)
      end

      it 'creates it silently: no new-conversation event and no automatic CRM deal' do
        allow(Rails.configuration.dispatcher).to receive(:dispatch).and_call_original
        allow(Crm::Deals::AutoCreateFromChannelContactService).to receive(:new).and_call_original
        reminder = build_reminder

        conversation = described_class.new(reminder: reminder).perform

        expect(conversation).to be_persisted
        expect(Rails.configuration.dispatcher).not_to have_received(:dispatch).with(Events::Types::CONVERSATION_CREATED, any_args)
        expect(Rails.configuration.dispatcher).not_to have_received(:dispatch).with(Events::Types::ASSIGNEE_CHANGED, any_args)
        expect(Crm::Deals::AutoCreateFromChannelContactService).not_to have_received(:new)
      end

      it 'returns a fresh record so that later updates raise their events as usual' do
        conversation = described_class.new(reminder: build_reminder).perform
        allow(Rails.configuration.dispatcher).to receive(:dispatch)

        conversation.update!(priority: :high)

        expect(conversation.skip_runtime_events).to be_falsey
        expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(Events::Types::CONVERSATION_UPDATED, kind_of(Time), any_args)
      end

      it 'links the notification conversation to a communication thread that stays resolved' do
        account.enable_features!('communication_threads')

        conversation = described_class.new(reminder: build_reminder).perform

        expect(conversation.reload.communication_thread).to be_present
        expect(conversation.communication_thread).to be_resolved
      end

      it 'creates a closed conversation for a blocked contact' do
        contact.update!(blocked: true)

        conversation = described_class.new(reminder: build_reminder).perform

        expect(conversation).to be_resolved
        expect(conversation.additional_attributes).to include('outbound_automated' => true)
      end
    end

    context 'when the inbox is an email inbox' do
      let(:inbox) { create(:channel_email, account: account).inbox }
      let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: contact.email) }

      it 'creates a closed notification conversation that carries the mail subject' do
        create_conversation(:resolved)
        reminder = build_reminder(metadata: { 'mail_subject' => 'Appointment reminder' })

        conversation = described_class.new(reminder: reminder).perform

        expect(conversation).to be_resolved
        expect(conversation.additional_attributes).to include(
          'mail_subject' => 'Appointment reminder',
          'outbound_automated' => true
        )
      end
    end

    context 'when the inbox has an active agent bot' do
      let(:bot_inbox) { create(:agent_bot_inbox) }
      let(:account) { bot_inbox.inbox.account }
      let(:inbox) { bot_inbox.inbox }

      before do
        inbox.update!(lock_to_single_conversation: false)
        # The bot starts every ordinary conversation as pending, so the earlier conversation is closed afterwards.
        create_conversation(:open).resolved!
      end

      it 'creates the notification conversation closed instead of pending' do
        expect(inbox.reload).to be_active_bot

        conversation = described_class.new(reminder: build_reminder).perform

        expect(conversation).to be_resolved
        expect(conversation.additional_attributes).to include('outbound_automated' => true)
      end
    end
  end
end
