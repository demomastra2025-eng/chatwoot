require 'rails_helper'

RSpec.describe 'Captain native ops tools' do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:account_owned_blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: File.open('spec/assets/avatar.png', 'rb'),
      filename: 'avatar.png',
      content_type: 'image/png',
      metadata: { 'account_id' => account.id }
    )
  end

  describe Captain::Tools::Copilot::SendMessageToConversationService do
    it 'sends a message to the target conversation' do
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(conversation_id: conversation.display_id, content: 'Hello from captain'))

      expect(payload['action']).to eq('send_message_to_conversation')
      expect(payload.dig('message', 'content')).to eq('Hello from captain')
      expect(conversation.reload.messages.outgoing.last.content).to eq('Hello from captain')
    end

    it 'sends selected attachments through the native message pipeline' do
      service = described_class.new(assistant, user: user, conversation: conversation)
      signed_blob_id = account_owned_blob.signed_id

      payload = JSON.parse(service.execute(
                             conversation_id: conversation.display_id,
                             content: '',
                             attachment_ids: [signed_blob_id]
                           ))

      expect(payload.dig('message', 'attachments', 0, 'file_type')).to eq('image')
      expect(conversation.reload.messages.outgoing.last.attachments.first.file.blob.signed_id).to eq(signed_blob_id)
    end
  end

  describe Captain::Tools::Copilot::ListChannelTemplatesService do
    it 'lists approved templates for the current WhatsApp conversation inbox' do
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      whatsapp_contact = create(:contact, account: account)
      whatsapp_contact_inbox = create(:contact_inbox, contact: whatsapp_contact, inbox: whatsapp_inbox)
      whatsapp_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: whatsapp_contact,
                                                    contact_inbox: whatsapp_contact_inbox)
      service = described_class.new(assistant, user: user, conversation: whatsapp_conversation)

      payload = JSON.parse(service.execute(name: 'sample_shipping_confirmation', language: 'en_US'))

      expect(payload['action']).to eq('list_channel_templates')
      expect(payload['supports_channel_templates']).to be(true)
      expect(payload.dig('templates', 0, 'name')).to eq('sample_shipping_confirmation')
      expect(payload.dig('templates', 0, 'required_params', 0, 'name')).to eq('1')
    end

    it 'explains that normal channels do not require templates' do
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute)

      expect(payload['action']).to eq('list_channel_templates')
      expect(payload['supports_channel_templates']).to be(false)
      expect(payload['templates']).to eq([])
      expect(payload['notes'].first).to include('does not require channel templates')
    end
  end

  describe Captain::Tools::Copilot::AssignConversationService do
    it 'assigns the conversation team and assignee' do
      service = described_class.new(assistant, user: user, conversation: conversation)
      team = create(:team, account: account)
      assignee = create(:user, account: account)
      create(:team_member, team: team, user: assignee)
      payload = JSON.parse(service.execute(
                             conversation_id: conversation.display_id,
                             assignee_id: assignee.id,
                             team_id: team.id
                           ))

      expect(payload.dig('conversation', 'assignee_id')).to eq(assignee.id)
      expect(payload.dig('conversation', 'team_id')).to eq(team.id)
      expect(conversation.reload.assignee_id).to eq(assignee.id)
      expect(conversation.reload.team_id).to eq(team.id)
    end
  end

  describe Captain::Tools::Copilot::RetryFailedMessageService do
    it 'retries a failed outgoing message' do
      service = described_class.new(assistant, user: user, conversation: conversation)
      message = create(:message, conversation: conversation, inbox: conversation.inbox, account: account,
                                 sender: user, message_type: 'outgoing', status: 'failed', content: 'Retry me')
      allow(SendReplyJob).to receive(:perform_later)

      payload = JSON.parse(service.execute(message_id: message.id))

      expect(payload['action']).to eq('retry_failed_message')
      expect(payload.dig('message', 'status')).to eq('sent')
      expect(message.reload.status).to eq('sent')
      expect(SendReplyJob).to have_received(:perform_later).with(message.id)
    end
  end

  describe Captain::Tools::Copilot::EditMessageService do
    it 'edits a message through the update content service' do
      service = described_class.new(assistant, user: user, conversation: conversation)
      message = create(:message, conversation: conversation, inbox: conversation.inbox, account: account,
                                 sender: user, message_type: 'outgoing', status: 'sent', content: 'Old content')
      editor = instance_double(Messages::UpdateContentService)
      allow(Messages::UpdateContentService).to receive(:new).and_return(editor)
      allow(editor).to receive(:perform) do
        message.update!(content: 'New content')
        message
      end

      payload = JSON.parse(service.execute(message_id: message.id, content: 'New content'))

      expect(payload.dig('message', 'content')).to eq('New content')
      expect(message.reload.content).to eq('New content')
    end
  end

  describe Captain::Tools::Copilot::TranslateMessageService do
    it 'translates and caches the message content' do
      service = described_class.new(assistant, user: user, conversation: conversation)
      message = create(:message, conversation: conversation, inbox: conversation.inbox, account: account)
      translator = instance_double(Integrations::GoogleTranslate::ProcessorService, perform: 'Привет')
      allow(Integrations::GoogleTranslate::ProcessorService).to receive(:new).and_return(translator)

      payload = JSON.parse(service.execute(message_id: message.id, target_language: 'ru'))

      expect(payload['content']).to eq('Привет')
      expect(message.reload.translations['ru']).to eq('Привет')
    end
  end

  describe Captain::Tools::Copilot::SearchCannedResponsesService do
    it 'returns matching canned responses' do
      create(:canned_response, account: account, short_code: 'shipping', content: 'Shipping response')
      create(:canned_response, account: account, short_code: 'billing', content: 'Billing response')
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(query: 'ship'))

      expect(payload['total_count']).to eq(1)
      expect(payload.dig('canned_responses', 0, 'short_code')).to eq('shipping')
    end
  end

  describe Captain::Tools::Copilot::CreateCannedResponseService do
    it 'creates a canned response' do
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(short_code: 'welcome', content: 'Welcome aboard'))

      expect(payload['action']).to eq('create_canned_response')
      expect(payload.dig('canned_response', 'short_code')).to eq('welcome')
      expect(account.canned_responses.find_by(short_code: 'welcome')).to be_present
    end
  end

  describe Captain::Tools::Copilot::MergeContactsService do
    it 'merges contacts into the base contact' do
      base_contact = create(:contact, account: account, email: 'base@example.com')
      mergee_contact = create(:contact, account: account, phone_number: '+77000000001')
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(base_contact_id: base_contact.id, mergee_contact_id: mergee_contact.id))

      expect(payload['action']).to eq('merge_contacts')
      expect(payload.dig('contact', 'id')).to eq(base_contact.id)
      expect(account.contacts.exists?(mergee_contact.id)).to be(false)
    end
  end

  describe Captain::Tools::Copilot::AddAppointmentPaymentService do
    it 'adds a payment to the current appointment' do
      account.enable_features!('scheduling', 'scheduling_finance')
      appointment = create(:scheduling_appointment, account: account, contact: conversation.contact, conversation: conversation)
      allow(Captain::ContextFields).to receive(:appointment_for).and_return(appointment)
      finance_service = instance_double(Scheduling::Appointments::FinanceSyncService, add_payment!: appointment)
      allow(Scheduling::Appointments::FinanceSyncService).to receive(:new).and_return(finance_service)
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(payment_method: 'cash', amount: 1500))

      expect(payload['action']).to eq('add_appointment_payment')
      expect(Scheduling::Appointments::FinanceSyncService).to have_received(:new)
    end
  end

  describe Captain::Tools::Copilot::ExecuteMacroService do
    it 'enqueues macro execution for the current conversation by default' do
      macro = create(:macro, account: account, created_by: user)
      service = described_class.new(assistant, user: user, conversation: conversation)
      allow(MacrosExecutionJob).to receive(:perform_later)

      payload = JSON.parse(service.execute(macro_id: macro.id))

      expect(payload['action']).to eq('execute_macro')
      expect(payload.dig('macro', 'conversation_display_ids')).to eq([conversation.display_id])
      expect(MacrosExecutionJob).to have_received(:perform_later).with(macro, conversation_ids: [conversation.display_id], user: user)
    end
  end

  describe Captain::Tools::Copilot::GetWhatsappWebDiagnosticsService do
    it 'returns diagnostics for a whatsapp web inbox' do
      channel = instance_double(Channel::WhatsappWeb, diagnostics: { 'status' => 'ok' })
      allow(channel).to receive(:is_a?).with(Channel::WhatsappWeb).and_return(true)
      inbox = instance_double(Inbox, id: 123, name: 'WA Inbox', channel: channel)
      allow(account.inboxes).to receive(:find).with(123).and_return(inbox)
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(inbox_id: 123))

      expect(payload['action']).to eq('get_whatsapp_web_diagnostics')
      expect(payload['diagnostics']).to eq({ 'status' => 'ok' })
    end
  end

  describe Captain::Tools::Copilot::ReconnectWhatsappWebService do
    it 'reconnects a whatsapp web inbox' do
      channel = instance_double(Channel::WhatsappWeb, reconnect!: true, phone_number: '+77000000000', lifecycle_state: 'connected',
                                                      connection_state: 'open', last_error: nil)
      allow(channel).to receive(:is_a?).with(Channel::WhatsappWeb).and_return(true)
      inbox = instance_double(Inbox, id: 456, name: 'WA Inbox', channel: channel, channel_type: 'Channel::WhatsappWeb', updated_at: Time.zone.now)
      allow(account.inboxes).to receive(:find).with(456).and_return(inbox)
      allow(inbox).to receive(:reload).and_return(inbox)
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(inbox_id: 456))

      expect(payload['action']).to eq('reconnect_whatsapp_web')
      expect(channel).to have_received(:reconnect!)
      expect(payload.dig('inbox', 'id')).to eq(456)
    end
  end

  describe Captain::Tools::Copilot::CreateLabelService do
    it 'creates a label' do
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(title: 'VIP', color: '#ff0000'))

      expect(payload['action']).to eq('create_label')
      expect(payload.dig('label', 'title')).to eq('vip')
      expect(account.labels.find_by(title: 'vip')).to be_present
    end
  end

  describe Captain::Tools::Copilot::UpdateLabelService do
    it 'updates a label' do
      label = create(:label, account: account, title: 'vip')
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(label_id: label.id, title: 'priority'))

      expect(payload['action']).to eq('update_label')
      expect(payload.dig('label', 'title')).to eq('priority')
      expect(label.reload.title).to eq('priority')
    end
  end

  describe Captain::Tools::Copilot::RemoveLabelFromConversationService do
    it 'removes a label from the current conversation' do
      conversation.add_labels(%w[vip support])
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(label_name: 'vip'))

      expect(payload['action']).to eq('remove_label_from_conversation')
      expect(conversation.reload.label_list).to eq(['support'])
    end
  end

  describe Captain::Tools::Copilot::ListCampaignsService do
    it 'lists campaigns' do
      create(:campaign, account: account, campaign_status: 'active')
      create(:campaign, account: account, campaign_status: 'failed')
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(campaign_status: 'active'))

      expect(payload['total_count']).to eq(1)
      expect(payload.dig('campaigns', 0, 'campaign_status')).to eq('active')
    end
  end

  describe Captain::Tools::Copilot::PreviewCampaignService do
    it 'returns preview payload' do
      inbox = create(:inbox, account: account)
      service = described_class.new(assistant, user: user, conversation: conversation)
      preview_service = instance_double(Campaigns::PreviewService, call: { 'preview' => 'ok' })
      allow(Campaigns::PreviewService).to receive(:new).and_return(preview_service)

      payload = JSON.parse(service.execute(inbox_id: inbox.id, audience: { 'type' => 'all' }, message: 'Hello'))

      expect(payload).to eq('preview' => 'ok')
    end
  end

  describe Captain::Tools::Copilot::GetCampaignAnalyticsService do
    it 'returns campaign analytics' do
      campaign = create(:campaign, account: account)
      service = described_class.new(assistant, user: user, conversation: conversation)
      analytics = { 'sent' => 10, 'failed' => 2 }
      analytics_service = instance_double(Campaigns::AnalyticsService, call: analytics)
      allow(Campaigns::AnalyticsService).to receive(:new).and_return(analytics_service)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id))

      expect(payload).to eq(analytics)
    end
  end

  describe Captain::Tools::Copilot::RetryFailedCampaignDeliveriesService do
    it 'retries failed deliveries and returns analytics' do
      campaign = create(:campaign, account: account)
      service = described_class.new(assistant, user: user, conversation: conversation)
      retry_service = instance_double(Campaigns::RetryFailedDeliveriesService, perform: true)
      analytics_service = instance_double(Campaigns::AnalyticsService, call: { 'retried' => true })
      allow(Campaigns::RetryFailedDeliveriesService).to receive(:new).and_return(retry_service)
      allow(Campaigns::AnalyticsService).to receive(:new).and_return(analytics_service)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id))

      expect(payload).to eq('retried' => true)
      expect(retry_service).to have_received(:perform)
    end
  end

  describe Captain::Tools::Copilot::CreateWebhookService do
    it 'creates a webhook' do
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(
                             url: 'https://example.com/hook',
                             subscriptions: %w[conversation_created message_created],
                             name: 'Captain Hook'
                           ))

      expect(payload['action']).to eq('create_webhook')
      expect(payload.dig('webhook', 'url')).to eq('https://example.com/hook')
      expect(account.webhooks.find_by(url: 'https://example.com/hook')).to be_present
    end
  end

  describe Captain::Tools::Copilot::UpdateWebhookService do
    it 'updates a webhook' do
      webhook = create(:webhook, account: account, inbox: nil, url: 'https://old.example.com')
      service = described_class.new(assistant, user: user, conversation: conversation)

      payload = JSON.parse(service.execute(
                             webhook_id: webhook.id,
                             url: 'https://new.example.com',
                             subscriptions: %w[conversation_updated]
                           ))

      expect(payload['action']).to eq('update_webhook')
      expect(payload.dig('webhook', 'url')).to eq('https://new.example.com')
      expect(webhook.reload.url).to eq('https://new.example.com')
    end
  end
end
