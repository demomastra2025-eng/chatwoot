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

    it 'auto-creates a CRM deal for a new conversation when the channel toggle is enabled' do
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

      deal = account.crm_deals.find_by!(pipeline: pipeline)

      expect(deal.stage_id).to eq(stage.id)
      expect(deal.originating_conversation_id).to eq(conversation.id)
      expect(deal.primary_contact_id).to eq(contact.id)
      expect(deal.idempotency_key).to eq("auto_channel_contact:pipeline:#{pipeline.id}:conversation:#{conversation.id}")
    end

    it 'auto-creates a CRM deal for an existing contact that starts a new channel conversation' do
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

      new_deal = account.crm_deals.kept.find_by!(pipeline: pipeline)
      expect(new_deal.id).not_to eq(archived_deal.id)
      expect(new_deal.originating_conversation_id).to eq(conversation.id)
      expect(new_deal.primary_contact_id).to eq(contact.id)
      expect(new_deal.idempotency_key).to eq("auto_channel_contact:pipeline:#{pipeline.id}:conversation:#{conversation.id}")
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

      described_class.new(
        contact_inbox: contact_api_inbox,
        params: {}
      ).perform

      expect(account.crm_deals.kept.where(pipeline: pipeline).count).to eq(1)
      expect(account.crm_deals.kept.find_by!(pipeline: pipeline)).to eq(active_deal)
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

      described_class.new(
        contact_inbox: contact_api_inbox,
        params: {}
      ).perform

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
  end
end
