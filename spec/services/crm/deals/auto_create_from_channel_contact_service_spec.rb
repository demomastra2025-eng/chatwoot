require 'rails_helper'

RSpec.describe Crm::Deals::AutoCreateFromChannelContactService do
  let(:account) { create(:account) }
  let(:api_inbox) { create(:inbox, channel: create(:channel_api, account: account), account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: api_inbox) }

  before do
    account.enable_features!('crm_deals')
    allow(Rails.logger).to receive(:warn)
  end

  describe '#perform' do
    let(:conversation) { create(:conversation, account: account, inbox: api_inbox, contact: contact, contact_inbox: contact_inbox) }

    def incoming
      create(:message, account: account, inbox: api_inbox, conversation: conversation, sender: contact)
    end

    def check(message)
      described_class.new(contact_inbox: contact_inbox, conversation: conversation, message: message).perform
    end

    it 'reuses active deals only in each enabled pipeline and creates again after all are closed' do
      pipeline = create(:crm_pipeline, account: account, auto_create_deal_on_channel_contact: true)
      stage = create(:crm_stage, account: account, pipeline: pipeline, default: true)
      first = check(incoming).first
      expect(check(incoming)).to eq([])
      expect(first.stage_id).to eq(stage.id)
      first.update!(closed_at: Time.current)
      second = check(incoming).first
      expect(second.id).not_to eq(first.id)
      expect(first.reload.closed_at).to be_present
    end

    it 'deduplicates a previously reused message even when the active deal closes before its retry' do
      pipeline = create(:crm_pipeline, account: account, auto_create_deal_on_channel_contact: true)
      create(:crm_stage, account: account, pipeline: pipeline, default: true)
      first_message = incoming
      deal = check(first_message).first
      repeated_message = incoming
      check(repeated_message)
      deal.update!(closed_at: Time.current)

      expect { check(first_message); check(repeated_message) }.not_to change(Crm::Deal, :count)
      expect(check(incoming).first).to be_present
    end

    it 'does not undo a newer close through a previously unprocessed queued inbound event' do
      pipeline = create(:crm_pipeline, account: account, auto_create_deal_on_channel_contact: true)
      create(:crm_stage, account: account, pipeline: pipeline, default: true)
      first = check(incoming).first
      pending = incoming
      first.update!(closed_at: pending.created_at + 1.second)

      expect { check(pending) }.not_to change(Crm::Deal, :count)
      expect(account.crm_events.where(event_type: 'channel_contact_checked', command_key: "auto_channel_contact:pipeline:#{pipeline.id}:message:#{pending.id}")).to exist
      travel_to(first.closed_at + 1.second) do
        expect(check(incoming).first).to be_present
      end
    end

    it 'does not let a deal in another or disabled pipeline block this enabled pipeline' do
      enabled = create(:crm_pipeline, account: account, auto_create_deal_on_channel_contact: true)
      create(:crm_stage, account: account, pipeline: enabled, default: true)
      disabled = create(:crm_pipeline, account: account)
      other = create(:crm_deal, account: account, pipeline: disabled)
      create(:crm_deal_contact, deal: other, account: account, contact: contact, primary: true)

      expect(check(incoming).map(&:pipeline_id)).to eq([enabled.id])
    end

    it 'ignores outgoing messages and private notes' do
      pipeline = create(:crm_pipeline, account: account, auto_create_deal_on_channel_contact: true)
      create(:crm_stage, account: account, pipeline: pipeline, default: true)
      outgoing = create(:message, account: account, conversation: conversation, inbox: api_inbox, message_type: 'outgoing')
      note = create(:message, account: account, conversation: conversation, inbox: api_inbox, private: true)

      expect(check(outgoing)).to eq([])
      expect(check(note)).to eq([])
      expect(account.crm_deals).not_to exist
    end

    it 'skips the deal and logs only the error code when the default stage requires a field the new deal lacks' do
      pipeline = create(:crm_pipeline, account: account, default: true, auto_create_deal_on_channel_contact: true)
      stage = create(:crm_stage, account: account, pipeline: pipeline, default: true)
      create(:crm_stage_field_requirement, stage: stage, field_key: 'description')

      expect(described_class.new(contact_inbox: contact_inbox).perform).to eq([])

      expect(account.crm_deals.where(pipeline: pipeline)).not_to exist
      expect(Rails.logger).to have_received(:warn).with(
        "Crm auto-create deal skipped: account_id=#{account.id} pipeline_id=#{pipeline.id} " \
        'error=Crm::Error code=DEAL_STAGE_REQUIRES_FIELDS'
      )
    end

    it 'still creates the deal in the next auto-create pipeline when one pipeline is skipped' do
      blocked = create(:crm_pipeline, account: account, default: true, auto_create_deal_on_channel_contact: true)
      blocked_stage = create(:crm_stage, account: account, pipeline: blocked, default: true)
      create(:crm_stage_field_requirement, stage: blocked_stage, field_key: 'description')
      open_pipeline = create(:crm_pipeline, account: account, auto_create_deal_on_channel_contact: true)
      open_stage = create(:crm_stage, account: account, pipeline: open_pipeline, default: true)

      deals = described_class.new(contact_inbox: contact_inbox).perform

      expect(deals.map(&:pipeline_id)).to eq([open_pipeline.id])
      expect(deals.first.stage_id).to eq(open_stage.id)
      expect(account.crm_deals.where(pipeline: blocked)).not_to exist
    end
  end
end
