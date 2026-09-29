require 'rails_helper'

RSpec.describe MessageTemplates::HookExecutionService do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox, account: account, contact: contact, status: :pending) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let!(:captain_inbox) { create(:captain_inbox, captain_assistant: assistant, inbox: inbox) }

  before do
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_on)
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
  end

  context 'when captain assistant is configured' do
    context 'when within business hours' do
      before do
        inbox.update!(working_hours_enabled: true)
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          open_all_day: true,
          closed_all_day: false
        )
      end

      it 'schedules captain response job for incoming messages on pending conversations' do
        expect(Captain::Conversation::TypingIndicatorService).to receive(:turn_on).with(
          conversation: conversation,
          assistant: assistant
        )
        expect(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later).with(
          conversation,
          assistant,
          hash_including(expected_last_message_id: kind_of(Integer))
        )

        create(:message, conversation: conversation, message_type: :incoming, account: account)
      end

      it 'schedules captain response within business hours when auto-reply mode is working_hours' do
        captain_inbox.update!(auto_reply_mode: 'working_hours')

        expect(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later).with(
          conversation,
          assistant,
          hash_including(expected_last_message_id: kind_of(Integer))
        )

        create(:message, conversation: conversation, message_type: :incoming, account: account)
      end

      it 'opens the conversation for people within business hours when auto-reply mode is outside_working_hours' do
        captain_inbox.update!(auto_reply_mode: 'outside_working_hours')

        expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)
        expect(Captain::Conversation::TypingIndicatorService).to receive(:turn_off).with(
          conversation: conversation,
          assistant: assistant
        )

        create(:message, conversation: conversation, message_type: :incoming, account: account)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.status_transitions.last).to have_attributes(
          from_status: 'pending', to_status: 'open', source: 'system', actor_id: nil, actor_type: nil
        )
        expect(conversation.messages.outgoing).to be_empty
        expect(conversation.captain_handoff_applied_at).to be_nil
      end

      it 'opens the conversation for people when auto-reply is off, even with the handoff tool disabled' do
        captain_inbox.update!(auto_reply_mode: 'outside_working_hours')
        assistant.update!(config: assistant.config.deep_merge(
          'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] } }
        ))

        expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)
        create(:message, conversation: conversation, message_type: :incoming, account: account)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.outgoing).to be_empty
      end

      it 'opens a brand-new conversation when Captain may not answer during working hours' do
        captain_inbox.update!(auto_reply_mode: 'outside_working_hours')
        new_conversation = create(:conversation, inbox: inbox, account: account, contact: contact)
        expect(new_conversation.reload.status).to eq('pending')

        expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)
        create(:message, conversation: new_conversation, message_type: :incoming, account: account)

        expect(new_conversation.reload.status).to eq('open')
      end

      it 'does not reopen a conversation that left pending before the schedule safety net runs' do
        captain_inbox.update!(auto_reply_mode: 'outside_working_hours')
        message = create(:message, conversation: conversation, message_type: :incoming, account: account)
        conversation.update!(status: :resolved)
        service = described_class.new(message: message.reload)

        service.send(:open_outside_captain_schedule)

        expect(conversation.reload.status).to eq('resolved')
      end

      it 'does not schedule captain response for voice_call bubble updates' do
        expect(Captain::Conversation::TypingIndicatorService).not_to receive(:turn_on)
        expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

        create(:message, conversation: conversation, message_type: :incoming, content_type: :voice_call, account: account)
      end
    end

    context 'when outside business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
      end

      it 'schedules captain response job outside business hours when auto-reply mode is always' do
        captain_inbox.update!(auto_reply_mode: 'always')

        expect(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later).with(
          conversation,
          assistant,
          hash_including(expected_last_message_id: kind_of(Integer))
        )

        create(:message, conversation: conversation, message_type: :incoming, account: account)
      end

      it 'sends out-of-office and opens the conversation outside business hours when auto-reply mode is working_hours' do
        captain_inbox.update!(auto_reply_mode: 'working_hours')
        out_of_office_service = instance_double(MessageTemplates::Template::OutOfOffice)
        allow(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office_service)
        allow(out_of_office_service).to receive(:perform).and_return(true)

        expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

        create(:message, conversation: conversation, message_type: :incoming, account: account)

        expect(MessageTemplates::Template::OutOfOffice).to have_received(:new)
        expect(conversation.reload.status).to eq('open')
        expect(conversation.status_transitions.last).to have_attributes(source: 'system', actor_id: nil)
      end

      it 'opens a brand-new conversation outside business hours when auto-reply mode is working_hours' do
        captain_inbox.update!(auto_reply_mode: 'working_hours')
        new_conversation = create(:conversation, inbox: inbox, account: account, contact: contact)
        expect(new_conversation.reload.status).to eq('pending')

        create(:message, conversation: new_conversation, message_type: :incoming, account: account)

        expect(new_conversation.reload.status).to eq('open')
        expect(new_conversation.messages.template.pluck(:content)).to include('We are currently closed')
      end

      it 'leaves voice call bubbles alone outside the Captain schedule' do
        captain_inbox.update!(auto_reply_mode: 'working_hours')

        create(:message, conversation: conversation, message_type: :incoming, content_type: :voice_call, account: account)

        expect(conversation.reload.status).to eq('pending')
        expect(conversation.status_transitions).to be_empty
      end

      it 'schedules captain response outside business hours when auto-reply mode is outside_working_hours' do
        captain_inbox.update!(auto_reply_mode: 'outside_working_hours')

        expect(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later).with(
          conversation,
          assistant,
          hash_including(expected_last_message_id: kind_of(Integer))
        )

        create(:message, conversation: conversation, message_type: :incoming, account: account)
      end

      it 'hands the conversation to people with the out-of-office template when the Captain quota is exceeded outside business hours' do
        account.update!(
          limits: { 'captain_responses' => 100 },
          custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 100)
        )

        expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)
        create(:message, conversation: conversation, message_type: :incoming, account: account)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.template.pluck(:content)).to include('We are currently closed')
        expect(conversation.messages.outgoing.where(content: 'Transferring to another agent for further assistance.')).to be_empty
      end

      it 'does not send out of office message when Captain is handling' do
        out_of_office_service = instance_double(MessageTemplates::Template::OutOfOffice)
        allow(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office_service)
        allow(out_of_office_service).to receive(:perform).and_return(true)

        create(:message, conversation: conversation, message_type: :incoming, account: account)

        expect(MessageTemplates::Template::OutOfOffice).not_to have_received(:new)
      end
    end

    context 'when business hours are not enabled' do
      before do
        inbox.update!(working_hours_enabled: false)
      end

      it 'schedules captain response job regardless of time' do
        expect(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later).with(
          conversation,
          assistant,
          hash_including(expected_last_message_id: kind_of(Integer))
        )

        create(:message, conversation: conversation, message_type: :incoming, account: account)
      end

      it 'opens every conversation when outside-hours auto-reply has no active window' do
        captain_inbox.update!(auto_reply_mode: 'outside_working_hours')

        expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

        create(:message, conversation: conversation, message_type: :incoming, account: account)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.status_transitions.last).to have_attributes(source: 'system', actor_id: nil)
      end
    end

    context 'when captain quota is exceeded within business hours' do
      before do
        inbox.update!(working_hours_enabled: true)
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          open_all_day: true,
          closed_all_day: false
        )

        account.update!(
          limits: { 'captain_responses' => 100 },
          custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 100)
        )
      end

      it 'hands the conversation to people within business hours when quota is exceeded' do
        expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)
        expect(Captain::Conversation::TypingIndicatorService).to receive(:turn_off).with(
          conversation: conversation,
          assistant: assistant
        )

        create(:message, conversation: conversation, message_type: :incoming, account: account)

        conversation.reload
        expect(conversation.status).to eq('open')
        expect(conversation.captain_handoff_applied_at).to be_present
        expect(conversation.status_transitions.last).to have_attributes(
          from_status: 'pending', to_status: 'open', source: 'system', actor_id: nil, actor_type: nil
        )
        expect(conversation.messages.outgoing.where(content: 'Transferring to another agent for further assistance.')).to be_empty
      end

      it 'sends only the assistant handoff message when quota is exceeded' do
        assistant.update!(config: assistant.config.merge(
          'handoff_message_enabled' => true, 'handoff_message_mode' => 'static', 'handoff_message' => 'Сейчас подключим администратора.'
        ))

        create(:message, conversation: conversation, message_type: :incoming, account: account)
        create(:message, conversation: conversation, message_type: :incoming, account: account)

        public_messages = conversation.reload.messages.outgoing.where(private: false)
        expect(conversation.status).to eq('open')
        expect(public_messages.pluck(:content)).to eq(['Сейчас подключим администратора.'])
        expect(public_messages.first.sender).to eq(assistant)
      end

      it 'sends no public handoff text when the assistant handoff message is not configured or disabled' do
        assistant.update!(config: assistant.config.merge('handoff_message_enabled' => true, 'handoff_message' => ''))
        create(:message, conversation: conversation, message_type: :incoming, account: account)
        disabled_conversation = create(:conversation, inbox: inbox, account: account, contact: contact, status: :pending)
        assistant.update!(config: assistant.config.merge('handoff_message_enabled' => false, 'handoff_message' => 'Handoff text'))
        create(:message, conversation: disabled_conversation, message_type: :incoming, account: account)

        [conversation, disabled_conversation].each do |candidate|
          expect(candidate.reload.status).to eq('open')
          expect(candidate.messages.outgoing).to be_empty
        end
      end

      it 'hands off on quota exhaustion even when the handoff tool is disabled, without the hard-coded transfer text' do
        assistant.update!(config: assistant.config.deep_merge(
          'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['faq_lookup'] } }
        ))

        create(:message, conversation: conversation, message_type: :incoming, account: account)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.outgoing.where(content: 'Transferring to another agent for further assistance.')).to be_empty
      end

      it 'sends the inbox greeting while Captain has no quota' do
        inbox.update!(greeting_enabled: true, greeting_message: 'Hello! How can we help you?', enable_email_collect: false)

        create(:message, conversation: conversation, message_type: :incoming, account: account)

        expect(conversation.reload.messages.template.pluck(:content)).to eq(['Hello! How can we help you?'])
        expect(conversation.status).to eq('open')
      end
    end
  end

  context 'when message collapse is enabled across channel types' do
    channel_factories = {
      'web widget' => [:channel_widget, {}],
      'api' => [:channel_api, {}],
      'whatsapp cloud' => [:channel_whatsapp, { validate_provider_config: false, sync_templates: false }],
      'whatsapp web' => [:channel_whatsapp_web, {}],
      'telegram bot' => [:channel_telegram, {}],
      'telegram personal' => [:channel_telegram_personal, {}],
      'sms' => [:channel_sms, {}],
      'email' => [:channel_email, {}],
      'voice' => [[:channel_voice, :sipuni], {}],
      'line' => [:channel_line, {}],
      'facebook page' => [:channel_facebook_page, {}],
      'instagram' => [:channel_instagram, {}]
    }

    before do
      Channel::WhatsappWeb.skip_callback(:validate, :before, :ensure_runtime_configuration)
      Channel::WhatsappWeb.skip_callback(:commit, :after, :enqueue_provisioning)
      Channel::FacebookPage.skip_callback(:commit, :after, :subscribe)
      allow(Telephony::NumberBinding).to receive(:sync_from_voice_channel!).and_return(true)
    end

    after do
      Channel::FacebookPage.set_callback(:commit, :after, :subscribe, on: :create)
      Channel::WhatsappWeb.set_callback(:commit, :after, :enqueue_provisioning, on: :create)
      Channel::WhatsappWeb.set_callback(:validate, :before, :ensure_runtime_configuration)
    end

    channel_factories.each do |channel_name, (factory_name, factory_options)|
      it "routes #{channel_name} incoming messages through the buffered scheduler" do
        channel_account = create(
          :account,
          custom_attributes: { plan_name: 'startups' },
          limits: { non_web_inboxes: ChatwootApp.max_limit }
        )
        channel = create(*Array(factory_name), account: channel_account, **factory_options)
        channel_inbox = channel.reload.inbox
        channel_contact = create(:contact, account: channel_account)
        channel_assistant = create(
          :captain_assistant,
          account: channel_account,
          config: { 'message_collapse_window_seconds' => 3 }
        )
        scheduler = instance_double(Captain::Conversation::BufferedResponseSchedulerService, perform: true)

        create(:captain_inbox, captain_assistant: channel_assistant, inbox: channel_inbox)
        channel_conversation = create(
          :conversation,
          inbox: channel_inbox,
          account: channel_account,
          contact: channel_contact,
          status: :pending
        )

        expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)
        expect(Captain::Conversation::BufferedResponseSchedulerService).to receive(:new).with(
          conversation: channel_conversation,
          assistant: channel_assistant,
          message: kind_of(Message),
          attachment_wait_time: 0.seconds
        ).and_return(scheduler)

        create(:message, conversation: channel_conversation, message_type: :incoming, account: channel_account)
      end
    end
  end

  context 'when no captain assistant is configured' do
    before do
      CaptainInbox.where(inbox: inbox).destroy_all
    end

    it 'does not schedule captain response job' do
      expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      create(:message, conversation: conversation, message_type: :incoming, account: account)
    end
  end

  context 'when conversation is not pending' do
    before do
      conversation.update!(status: :open)
    end

    it 'does not schedule captain response job' do
      expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      create(:message, conversation: conversation, message_type: :incoming, account: account)
    end

    it 'does not schedule captain response for open conversations with the old setting enabled' do
      captain_inbox.update!(reply_to_open_conversations: true)

      expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      create(:message, conversation: conversation, message_type: :incoming, account: account)
    end
  end

  context 'when message is outgoing' do
    it 'does not schedule captain response job' do
      expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

      create(:message, conversation: conversation, message_type: :outgoing, account: account)
    end
  end

  context 'when greeting and out of office messages with Captain enabled' do
    context 'when conversation is pending (Captain is handling)' do
      before do
        conversation.update!(status: :pending)
      end

      it 'does not create greeting message in conversation' do
        inbox.update!(greeting_enabled: true, greeting_message: 'Hello! How can we help you?', enable_email_collect: false)

        expect do
          create(:message, conversation: conversation, message_type: :incoming, account: account)
        end.not_to(change { conversation.reload.messages.template.count })
      end

      it 'does not create out of office message in conversation' do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed',
          enable_email_collect: false
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )

        expect do
          create(:message, conversation: conversation, message_type: :incoming, account: account)
        end.not_to(change { conversation.reload.messages.template.count })
      end
    end

    context 'when conversation is open (transferred to agent)' do
      before do
        conversation.update!(status: :open)
      end

      it 'creates greeting message in conversation' do
        inbox.update!(greeting_enabled: true, greeting_message: 'Hello! How can we help you?', enable_email_collect: false)

        expect do
          create(:message, conversation: conversation, message_type: :incoming, account: account)
        end.to change { conversation.reload.messages.template.count }.by(1)

        greeting_message = conversation.reload.messages.template.last
        expect(greeting_message.content).to eq('Hello! How can we help you?')
      end

      it 'creates out of office message when outside business hours' do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed',
          enable_email_collect: false
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )

        expect do
          create(:message, conversation: conversation, message_type: :incoming, account: account)
        end.to change { conversation.reload.messages.template.count }.by(1)

        out_of_office_message = conversation.reload.messages.template.last
        expect(out_of_office_message.content).to eq('We are currently closed')
      end

      it 'uses the out-of-office template instead of Captain for open conversations outside business hours' do
        captain_inbox.update!(auto_reply_mode: 'outside_working_hours', reply_to_open_conversations: true)
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed',
          enable_email_collect: false
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )

        expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)

        expect do
          create(:message, conversation: conversation, message_type: :incoming, account: account)
        end.to change { conversation.reload.messages.template.count }.by(1)
      end
    end
  end

  context 'when Captain is not configured' do
    before do
      CaptainInbox.where(inbox: inbox).destroy_all
    end

    it 'creates greeting message in conversation' do
      inbox.update!(greeting_enabled: true, greeting_message: 'Hello! How can we help you?', enable_email_collect: false)

      expect do
        create(:message, conversation: conversation, message_type: :incoming, account: account)
      end.to change { conversation.reload.messages.template.count }.by(1)

      greeting_message = conversation.reload.messages.template.last
      expect(greeting_message.content).to eq('Hello! How can we help you?')
    end

    it 'creates out of office message when outside business hours' do
      inbox.update!(
        working_hours_enabled: true,
        out_of_office_message: 'We are currently closed',
        enable_email_collect: false
      )
      inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
        closed_all_day: true,
        open_all_day: false
      )

      expect do
        create(:message, conversation: conversation, message_type: :incoming, account: account)
      end.to change { conversation.reload.messages.template.count }.by(1)

      out_of_office_message = conversation.reload.messages.template.last
      expect(out_of_office_message.content).to eq('We are currently closed')
    end
  end

  context 'when conversation has a campaign' do
    let(:campaign) { create(:campaign, account: account) }
    let(:campaign_conversation) { create(:conversation, inbox: inbox, account: account, contact: contact, status: :pending, campaign: campaign) }

    it 'schedules captain response job for incoming messages on pending campaign conversations' do
      expect(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later).with(
        campaign_conversation,
        assistant,
        hash_including(expected_last_message_id: kind_of(Integer))
      )

      create(:message, conversation: campaign_conversation, message_type: :incoming, account: account)
    end

    it 'does not send greeting template on campaign conversations' do
      inbox.update!(greeting_enabled: true, greeting_message: 'Hello! How can we help you?', enable_email_collect: false)

      greeting_service = instance_double(MessageTemplates::Template::Greeting)
      allow(MessageTemplates::Template::Greeting).to receive(:new).and_return(greeting_service)
      allow(greeting_service).to receive(:perform).and_return(true)

      create(:message, conversation: campaign_conversation, message_type: :incoming, account: account)

      expect(MessageTemplates::Template::Greeting).not_to have_received(:new)
    end

    it 'does not send out of office template on campaign conversations' do
      inbox.update!(working_hours_enabled: true, out_of_office_message: 'We are currently closed')
      inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
        closed_all_day: true,
        open_all_day: false
      )

      out_of_office_service = instance_double(MessageTemplates::Template::OutOfOffice)
      allow(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office_service)
      allow(out_of_office_service).to receive(:perform).and_return(true)

      create(:message, conversation: campaign_conversation, message_type: :incoming, account: account)

      expect(MessageTemplates::Template::OutOfOffice).not_to have_received(:new)
    end

    it 'does not send email collect template on campaign conversations' do
      contact.update!(email: nil)
      inbox.update!(enable_email_collect: true)

      email_collect_service = instance_double(MessageTemplates::Template::EmailCollect)
      allow(MessageTemplates::Template::EmailCollect).to receive(:new).and_return(email_collect_service)
      allow(email_collect_service).to receive(:perform).and_return(true)

      create(:message, conversation: campaign_conversation, message_type: :incoming, account: account)

      expect(MessageTemplates::Template::EmailCollect).not_to have_received(:new)
    end

    it 'does not send out of office template after handoff on campaign conversations when quota is exceeded' do
      account.update!(
        limits: { 'captain_responses' => 100 },
        custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 100)
      )
      inbox.update!(
        working_hours_enabled: true,
        out_of_office_message: 'We are currently closed'
      )
      inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
        closed_all_day: true,
        open_all_day: false
      )

      expect do
        create(:message, conversation: campaign_conversation, message_type: :incoming, account: account)
      end.not_to(change { campaign_conversation.messages.template.count })
    end
  end

  context 'when Captain quota is exceeded without an AI tool call' do
    before do
      account.update!(
        limits: { 'captain_responses' => 100 },
        custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 100)
      )
    end

    context 'when outside business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed. Please leave your email.',
          enable_email_collect: false
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
      end

      it 'sends the out-of-office template once and opens the conversation when quota is exceeded' do
        expect do
          create(:message, conversation: conversation, message_type: :incoming, account: account)
        end.to change { conversation.messages.template.count }.by(1)

        expect(conversation.reload.status).to eq('open')
        expect(conversation.messages.template.last.content).to eq('We are currently closed. Please leave your email.')
      end
    end

    context 'when within business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed.',
          enable_email_collect: false
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          open_all_day: true,
          closed_all_day: false
        )
      end

      it 'does not send out of office message during working hours' do
        expect do
          create(:message, conversation: conversation, message_type: :incoming, account: account)
        end.not_to(change { conversation.messages.template.count })

        expect(conversation.reload.status).to eq('open')
      end
    end
  end
end
