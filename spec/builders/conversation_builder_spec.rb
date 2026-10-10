require 'rails_helper'

describe ConversationBuilder do
  let(:account) { create(:account) }
  let!(:sms_channel) { create(:channel_sms, account: account) }
  let!(:api_channel) { create(:channel_api, account: account) }
  let!(:sms_inbox) { create(:inbox, channel: sms_channel, account: account) }
  let!(:api_inbox) { create(:inbox, channel: api_channel, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_sms_inbox) { create(:contact_inbox, contact: contact, inbox: sms_inbox) }
  let(:contact_api_inbox) { create(:contact_inbox, contact: contact, inbox: api_inbox) }

  def receive_incoming(conversation)
    message = nil
    inbound_jobs = lambda do |job|
      job.is_a?(Crm::Appointments::InboundDealJob) ||
        (job.is_a?(EventDispatcherJob) && job.arguments.first == 'message.created')
    end
    perform_enqueued_jobs(only: inbound_jobs) do
      message = create(:message, account: account, inbox: conversation.inbox, conversation: conversation, sender: conversation.contact)
    end
    message
  end

  describe '#perform' do
    it 'creates sms conversation' do
      conversation = described_class.new(
        contact_inbox: contact_sms_inbox,
        params: {}
      ).perform

      expect(conversation.contact_inbox_id).to eq(contact_sms_inbox.id)
    end

    it 'creates api conversation' do
      conversation = described_class.new(
        contact_inbox: contact_api_inbox,
        params: {}
      ).perform

      expect(conversation.contact_inbox_id).to eq(contact_api_inbox.id)
    end

    it 'auto-creates a CRM deal only after a new conversation receives an incoming message when enabled' do
      account.enable_features!('crm_deals')
      pipeline = create(
        :crm_pipeline,
        account: account,
        default: true,
        auto_create_deal_on_channel_contact: true
      )
      stage = create(:crm_stage, account: account, pipeline: pipeline, default: true)

      conversation = described_class.new(
        contact_inbox: contact_api_inbox,
        params: {}
      ).perform

      expect(account.crm_deals.where(pipeline: pipeline)).not_to exist
      message = receive_incoming(conversation)
      deal = account.crm_deals.find_by!(pipeline: pipeline)

      expect(deal.stage_id).to eq(stage.id)
      expect(deal.originating_conversation_id).to eq(conversation.id)
      expect(deal.primary_contact_id).to eq(contact.id)
      expect(deal.idempotency_key).to eq("auto_channel_contact:pipeline:#{pipeline.id}:message:#{message.id}")
      expect(account.crm_events.where(eventable: contact, event_type: 'channel_contact_checked', command_key: deal.idempotency_key)).to exist
    end

    it 'recovers a database idempotency collision without aborting the caller transaction' do
      conversation = create(
        :conversation,
        account: account,
        inbox: api_inbox,
        contact: contact,
        contact_inbox: contact_api_inbox
      )
      account.enable_features!('crm_deals')
      pipeline = create(:crm_pipeline, account: account, default: true, auto_create_deal_on_channel_contact: true)
      stage = create(:crm_stage, account: account, pipeline: pipeline, default: true)
      message = create(:message, account: account, inbox: api_inbox, conversation: conversation, sender: contact)
      idempotency_key = "auto_channel_contact:pipeline:#{pipeline.id}:message:#{message.id}"
      create(:crm_deal, account: account, pipeline: pipeline, stage: stage, idempotency_key: idempotency_key)
      uniqueness_validator = Crm::Deal.validators_on(:idempotency_key).find { |validator| validator.kind == :uniqueness }
      allow(uniqueness_validator).to receive(:validate_each).and_call_original
      allow(uniqueness_validator).to receive(:validate_each).with(kind_of(Crm::Deal), :idempotency_key, idempotency_key)
                                                         .and_return(nil)
      collision = nil
      allow(Crm::Deals::UpsertService).to receive(:new).and_wrap_original do |method, **arguments|
        upsert = method.call(**arguments)
        # Simulate this key racing past the two application uniqueness checks; all other validation still runs.
        allow(upsert).to receive(:ensure_unique_reference!).and_call_original
        allow(upsert).to receive(:ensure_unique_reference!).with(
          scope: account.crm_deals, attribute: :idempotency_key, value: idempotency_key, code: 'DUPLICATE_IDEMPOTENCY_KEY'
        ).and_return(nil)
        allow(upsert).to receive(:perform).and_wrap_original do |perform|
          perform.call
        rescue ActiveRecord::RecordNotUnique => error
          collision = error
          raise
        end
        upsert
      end

      ActiveRecord::Base.transaction do
        expect(
          Crm::Deals::AutoCreateFromChannelContactService.new(
            contact_inbox: contact_api_inbox,
            conversation: conversation,
            message: message
          ).perform
        ).to be_empty
        expect(collision).to be_a(ActiveRecord::RecordNotUnique)
        expect(account.crm_deals.count).to eq(1)
        expect(ActiveRecord::Base.connection.select_value('SELECT 1')).to eq(1)
      end
    end

    it 'does not fail the conversation when the default stage has a required field the new deal cannot have' do
      account.enable_features!('crm_deals')
      pipeline = create(:crm_pipeline, account: account, default: true, auto_create_deal_on_channel_contact: true)
      stage = create(:crm_stage, account: account, pipeline: pipeline, default: true)
      create(:crm_stage_field_requirement, stage: stage, field_key: 'description')
      conversation = nil

      expect do
        conversation = described_class.new(contact_inbox: contact_api_inbox, params: {}).perform
        expect(receive_incoming(conversation)).to be_persisted
      end.not_to raise_error

      expect(conversation).to be_persisted
      expect(account.crm_deals.where(pipeline: pipeline)).not_to exist
    end

    it 'raises a database uniqueness collision with no matching idempotency key' do
      account.enable_features!('crm_deals')
      pipeline = create(:crm_pipeline, account: account, default: true, auto_create_deal_on_channel_contact: true)
      create(:crm_stage, account: account, pipeline: pipeline, default: true)
      upsert = instance_double(Crm::Deals::UpsertService)
      allow(Crm::Deals::UpsertService).to receive(:new).and_return(upsert)
      allow(upsert).to receive(:perform).and_raise(ActiveRecord::RecordNotUnique)
      conversation = described_class.new(contact_inbox: contact_api_inbox, params: {}).perform
      message = create(:message, account: account, inbox: api_inbox, conversation: conversation, sender: contact)

      expect do
        Crm::Deals::AutoCreateFromChannelContactService.new(
          contact_inbox: contact_api_inbox, conversation: conversation, message: message
        ).perform
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'auto-creates a CRM deal when an existing contact sends an incoming message in a new channel conversation' do
      account.enable_features!('crm_deals')
      pipeline = create(
        :crm_pipeline,
        account: account,
        default: true,
        auto_create_deal_on_channel_contact: true
      )
      create(:crm_stage, account: account, pipeline: pipeline, default: true)

      conversation = described_class.new(
        contact_inbox: contact_sms_inbox,
        params: {}
      ).perform
      receive_incoming(conversation)

      expect(account.crm_deals.find_by!(pipeline: pipeline)).to have_attributes(
        originating_conversation_id: conversation.id,
        primary_contact_id: contact.id
      )
    end

    it 'auto-creates a CRM deal when the contact only has archived deals in the pipeline' do
      account.enable_features!('crm_deals')
      pipeline = create(
        :crm_pipeline,
        account: account,
        default: true,
        auto_create_deal_on_channel_contact: true
      )
      stage = create(:crm_stage, account: account, pipeline: pipeline, default: true)
      archived_deal = create(
        :crm_deal,
        account: account,
        pipeline: pipeline,
        stage: stage,
        archived_at: 1.day.ago,
        idempotency_key: "auto_channel_contact:pipeline:#{pipeline.id}:contact:#{contact.id}"
      )
      create(:crm_deal_contact, account: account, deal: archived_deal, contact: contact, primary: true)

      conversation = described_class.new(
        contact_inbox: contact_api_inbox,
        params: {}
      ).perform
      message = receive_incoming(conversation)

      new_deal = account.crm_deals.kept.find_by!(pipeline: pipeline)
      expect(new_deal.id).not_to eq(archived_deal.id)
      expect(new_deal.originating_conversation_id).to eq(conversation.id)
      expect(new_deal.primary_contact_id).to eq(contact.id)
      expect(new_deal.idempotency_key).to eq("auto_channel_contact:pipeline:#{pipeline.id}:message:#{message.id}")
      expect(archived_deal.reload.archived_at).to be_present
    end

    it 'does not auto-create a duplicate CRM deal when the contact has an active deal in the pipeline' do
      account.enable_features!('crm_deals')
      pipeline = create(
        :crm_pipeline,
        account: account,
        default: true,
        auto_create_deal_on_channel_contact: true
      )
      stage = create(:crm_stage, account: account, pipeline: pipeline, default: true)
      active_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
      create(:crm_deal_contact, account: account, deal: active_deal, contact: contact, primary: true)

      conversation = described_class.new(
        contact_inbox: contact_api_inbox,
        params: {}
      ).perform
      receive_incoming(conversation)

      expect(account.crm_deals.kept.where(pipeline: pipeline).count).to eq(1)
      expect(account.crm_deals.kept.find_by!(pipeline: pipeline)).to eq(active_deal)
    end

    it 'reuses the same pipeline deal on each incoming message and creates a new deal after it closes' do
      account.enable_features!('crm_deals')
      pipeline = create(:crm_pipeline, account: account, default: true, auto_create_deal_on_channel_contact: true)
      stage = create(:crm_stage, account: account, pipeline: pipeline, default: true)
      conversation = described_class.new(contact_inbox: contact_api_inbox, params: {}).perform
      first_message = receive_incoming(conversation)
      first_deal = account.crm_deals.find_by!(pipeline: pipeline)
      repeated_message = receive_incoming(conversation)

      expect(account.crm_deals.where(pipeline: pipeline).pluck(:id)).to eq([first_deal.id])
      first_deal.update!(closed_at: Time.current)
      next_message = nil
      travel_to(first_deal.closed_at + 1.second) { next_message = receive_incoming(conversation) }

      new_deal = account.crm_deals.active.find_by!(pipeline: pipeline)
      expect(new_deal).to have_attributes(
        stage_id: stage.id, originating_conversation_id: conversation.id,
        idempotency_key: "auto_channel_contact:pipeline:#{pipeline.id}:message:#{next_message.id}"
      )
      expect(new_deal.primary_contact_id).to eq(contact.id)
      expect(new_deal.id).not_to eq(first_deal.id)
      expect(first_deal.reload.closed_at).to be_present
      expect(account.crm_deals.kept.where(pipeline: pipeline).count).to eq(2)
      expect(pipeline.reload.auto_create_deal_on_channel_contact).to be(true)
      keys = [first_message, repeated_message, next_message].map { |message| "auto_channel_contact:pipeline:#{pipeline.id}:message:#{message.id}" }
      expect(account.crm_events.where(eventable: contact, event_type: 'channel_contact_checked').pluck(:command_key)).to match_array(keys)
      expect do
        Crm::Appointments::InboundDealJob.perform_now(account.id, first_message.id)
        Crm::Appointments::InboundDealJob.perform_now(account.id, repeated_message.id)
      end.not_to change(Crm::Deal, :count)
      expect(account.crm_events.where(eventable: contact, event_type: 'channel_contact_checked').count).to eq(3)
    end

    it 'auto-creates CRM deals in active pipelines with the auto-create toggle enabled' do
      account.enable_features!('crm_deals')
      disabled_default_pipeline = create(
        :crm_pipeline,
        account: account,
        default: true,
        auto_create_deal_on_channel_contact: false
      )
      enabled_pipeline = create(
        :crm_pipeline,
        account: account,
        auto_create_deal_on_channel_contact: true
      )
      create(:crm_stage, account: account, pipeline: disabled_default_pipeline, default: true)
      create(:crm_stage, account: account, pipeline: enabled_pipeline, default: true)

      conversation = described_class.new(
        contact_inbox: contact_api_inbox,
        params: {}
      ).perform
      receive_incoming(conversation)

      expect(account.crm_deals.where(pipeline: disabled_default_pipeline)).not_to exist
      expect(account.crm_deals.where(pipeline: enabled_pipeline)).to exist
    end

    context 'when lock_to_single_conversation is true for sms inbox' do
      before do
        sms_inbox.update!(lock_to_single_conversation: true)
      end

      it 'creates sms conversation when existing conversation is not present' do
        conversation = described_class.new(
          contact_inbox: contact_sms_inbox,
          params: {}
        ).perform

        expect(conversation.contact_inbox_id).to eq(contact_sms_inbox.id)
      end

      it 'returns last from existing sms conversations when existing conversation is not present' do
        create(:conversation, contact_inbox: contact_sms_inbox)
        existing_conversation = create(:conversation, contact_inbox: contact_sms_inbox)
        conversation = described_class.new(
          contact_inbox: contact_sms_inbox,
          params: {}
        ).perform

        expect(conversation.id).to eq(existing_conversation.id)
      end
    end

    context 'when lock_to_single_conversation is true for api inbox' do
      before do
        api_inbox.update!(lock_to_single_conversation: true)
      end

      it 'creates conversation when existing api conversation is not present' do
        conversation = described_class.new(
          contact_inbox: contact_api_inbox,
          params: {}
        ).perform

        expect(conversation.contact_inbox_id).to eq(contact_api_inbox.id)
      end

      it 'returns last from existing api conversations when existing conversation is not present' do
        create(:conversation, contact_inbox: contact_api_inbox)
        existing_conversation = create(:conversation, contact_inbox: contact_api_inbox)
        conversation = described_class.new(
          contact_inbox: contact_api_inbox,
          params: {}
        ).perform

        expect(conversation.id).to eq(existing_conversation.id)
      end
    end

    it 'syncs website pre-chat conversations into widget lead submissions' do
      account.enable_features!('crm_deals')
      channel = create(:channel_widget, account: account, pre_chat_form_enabled: true)
      contact = create(:contact, account: account, name: 'Widget Client')
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: 'widget-client-1')

      LeadForms::WidgetSyncService.new(account: account).perform

      params = ActionController::Parameters.new(
        custom_attributes: {
          fullName: 'Widget Client',
          phoneNumber: '+77001234567'
        }
      )
      conversation = described_class.new(params: params, contact_inbox: contact_inbox).perform
      submission = account.lead_submissions.last

      expect(submission).to be_processed
      expect(submission.source_kind).to eq('widget')
      expect(submission.conversation).to eq(conversation)
      expect(submission.contact).to eq(contact)
      expect(submission.field_values).to include('fullName' => 'Widget Client')
      lead_message = conversation.messages.find_by!(source_id: "lead_submission:#{submission.id}")
      expect(lead_message.content_type).to eq('form')
      submitted_values = lead_message.content_attributes['submitted_values']
      phone_value = submitted_values.map(&:with_indifferent_access).find { |value| value[:name] == 'phoneNumber' }
      expect(phone_value[:value]).to eq(submission.field_values['phoneNumber'])
      expect(account.crm_deals.count).to eq(0)
    end
  end
end
