require 'rails_helper'

RSpec.describe Campaigns::PreviewService do
  let(:account) { create(:account) }
  let(:label) { create(:label, account: account, title: 'VIP') }
  let(:audience) { [{ type: 'Label', id: label.id }] }

  before do
    stub_request(:post, /graph.facebook.com/).to_return(status: 200, body: '{}', headers: {})
  end

  describe '#call' do
    it 'uses the immutable imported audience instead of current labels' do
      inbox = create(:inbox, account: account, channel: create(:channel_sms, account: account))
      imported_contact = create(:contact, account: account, phone_number: '+77051234567')
      labelled_contact = create(:contact, account: account, phone_number: '+77051234568')
      labelled_contact.update_labels([label.title])
      audience_import = create(:campaign_audience_import, account: account, inbox: inbox)
      create(
        :campaign_audience_recipient,
        campaign_audience_import: audience_import,
        account: account,
        contact: imported_contact,
        normalized_phone_number: imported_contact.phone_number
      )

      result = described_class.new(
        account: account,
        inbox: inbox,
        audience: audience,
        audience_import: audience_import
      ).call

      expect(result[:audience_size]).to eq(1)
      expect(result[:sample_contacts].pluck(:id)).to eq([imported_contact.id])
      expect(result[:sample_contacts].first[:target_identifier]).to eq('+77051234567')

      imported_contact.update!(phone_number: '+77050000000')
      refreshed_result = described_class.new(
        account: account,
        inbox: inbox,
        audience: audience,
        audience_import: audience_import
      ).call
      expect(refreshed_result[:sample_contacts].first[:target_identifier]).to eq('+77051234567')
    end

    it 'retains deleted imported recipients as non-deliverable snapshot entries' do
      inbox = create(:inbox, account: account, channel: create(:channel_sms, account: account))
      contact = create(:contact, account: account, phone_number: '+77051234567')
      audience_import = create(:campaign_audience_import, account: account, inbox: inbox)
      recipient = create(
        :campaign_audience_recipient,
        campaign_audience_import: audience_import,
        account: account,
        contact: contact,
        normalized_phone_number: contact.phone_number
      )

      contact.destroy!
      result = described_class.new(account: account, inbox: inbox, audience: [], audience_import: audience_import).call

      expect(recipient.reload.contact_id).to be_nil
      expect(recipient.normalized_phone_number).to eq('+77051234567')
      expect(result[:audience_size]).to eq(1)
      expect(result[:deliverable_count]).to eq(0)
      expect(result[:totals]['contact_deleted']).to eq(1)
      expect(result[:sample_contacts].first).to include(id: nil, reason: 'contact_deleted', deliverable: false)
    end

    it 'blocks blocked contacts in preview' do
      inbox = create(:inbox, account: account, channel: create(:channel_sms, account: account))
      contact = create(:contact, account: account, phone_number: '+77051234569', blocked: true)
      contact.update_labels([label.title])

      result = described_class.new(account: account, inbox: inbox, audience: audience).call

      expect(result[:deliverable_count]).to eq(0)
      expect(result[:totals]['blocked']).to eq(1)
      expect(result[:sample_contacts].first[:reason]).to eq('blocked')
    end

    it 'marks sms contacts with phone numbers as deliverable' do
      inbox = create(:inbox, account: account, channel: create(:channel_sms, account: account))
      contact = create(:contact, account: account, phone_number: '+15550001111')
      contact.label_list.add(label.title)
      contact.save!

      result = described_class.new(account: account, inbox: inbox, audience: audience).call

      expect(result[:audience_size]).to eq(1)
      expect(result[:deliverable_count]).to eq(1)
      expect(result[:totals]['deliverable']).to eq(1)
      expect(result[:sample_contacts].first[:reason]).to eq('deliverable')
      expect(result[:sample_contacts].first[:target_identifier]).to eq(contact.phone_number)
    end

    it 'includes contacts selected through labelled conversations' do
      inbox = create(:inbox, account: account, channel: create(:channel_telegram_personal, account: account))
      contact = create(
        :contact,
        account: account,
        phone_number: '+15550001114',
        additional_attributes: { 'social_telegram_user_id' => '9911' }
      )
      contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: '9911')
      create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox).update_labels([label.title])

      result = described_class.new(account: account, inbox: inbox, audience: audience).call

      expect(result[:audience_size]).to eq(1)
      expect(result[:deliverable_count]).to eq(1)
      expect(result[:totals]['deliverable']).to eq(1)
      expect(result[:sample_contacts].first[:target_identifier]).to eq('9911')
    end

    it 'requires whatsapp templates when the contact is outside the reply window' do
      account.enable_features!(:whatsapp_campaign)
      channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      inbox = channel.inbox
      contact = create(:contact, account: account, phone_number: '+15550001112')
      contact.label_list.add(label.title)
      contact.save!

      result = described_class.new(account: account, inbox: inbox, audience: audience).call

      expect(result[:audience_size]).to eq(1)
      expect(result[:deliverable_count]).to eq(0)
      expect(result[:totals]['requires_template']).to eq(1)
      expect(result[:sample_contacts].first[:reason]).to eq('requires_template')
    end

    it 'requires whatsapp templates when a scheduled free-text campaign will deliver after the reply window closes' do
      account.enable_features!(:whatsapp_campaign)
      channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      inbox = channel.inbox
      contact = create(:contact, account: account, phone_number: '+15550001115')
      contact.label_list.add(label.title)
      contact.save!
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: 1.hour.ago)

      result = described_class.new(account: account, inbox: inbox, audience: audience, scheduled_at: 25.hours.from_now).call

      expect(result[:deliverable_count]).to eq(0)
      expect(result[:totals]['requires_template']).to eq(1)
      expect(result[:sample_contacts].first[:reason]).to eq('requires_template')
    end

    it 'treats whatsapp contacts as deliverable when template params are present' do
      account.enable_features!(:whatsapp_campaign)
      channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      inbox = channel.inbox
      contact = create(:contact, account: account, phone_number: '+15550001113')
      contact.label_list.add(label.title)
      contact.save!
      template_params = {
        name: 'ticket_status_updated',
        language: 'en',
        category: 'UTILITY',
        processed_params: { name: 'John', ticket_id: '123' }
      }

      result = described_class.new(
        account: account,
        inbox: inbox,
        audience: audience,
        template_params: template_params
      ).call

      expect(result[:deliverable_count]).to eq(1)
      expect(result[:totals]['deliverable']).to eq(1)
      expect(result[:sample_contacts].first[:reason]).to eq('deliverable')
    end

    it 'treats email contacts as deliverable in the shared runner' do
      channel = create(:channel_email, account: account)
      inbox = channel.inbox
      contact = create(:contact, account: account, email: 'vip@example.com')
      contact.label_list.add(label.title)
      contact.save!

      result = described_class.new(account: account, inbox: inbox, audience: audience).call

      expect(result[:deliverable_count]).to eq(1)
      expect(result[:totals]['deliverable']).to eq(1)
      expect(result[:sample_contacts].first[:reason]).to eq('deliverable')
      expect(result[:sample_contacts].first[:target_identifier]).to eq('vip@example.com')
    end

    it 'blocks facebook contacts outside the reply window when a target exists but no active conversation window exists' do
      channel = create(:channel_facebook_page, account: account, inbox: nil)
      inbox = create(:inbox, account: account, channel: channel)
      contact = create(:contact, account: account)
      contact.label_list.add(label.title)
      contact.save!
      create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'fb-user-1')

      result = described_class.new(account: account, inbox: inbox, audience: audience).call

      expect(result[:deliverable_count]).to eq(0)
      expect(result[:totals]['outside_reply_window']).to eq(1)
      expect(result[:sample_contacts].first[:reason]).to eq('outside_reply_window')
      expect(result[:sample_contacts].first[:target_identifier]).to eq('fb-user-1')
    end

    it 'uses the latest conversation with an incoming message for reply-window channels instead of a newer outbound campaign conversation' do
      channel = create(:channel_facebook_page, account: account, inbox: nil)
      inbox = create(:inbox, account: account, channel: channel)
      contact = create(:contact, account: account)
      contact.label_list.add(label.title)
      contact.save!
      contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'fb-user-2')

      inbound_conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      create(
        :message,
        account: account,
        inbox: inbox,
        conversation: inbound_conversation,
        sender: contact,
        message_type: :incoming,
        created_at: 2.hours.ago
      )

      campaign = create(:campaign, account: account, inbox: inbox)
      campaign_conversation = create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        campaign: campaign
      )
      create(
        :message,
        :bot_message,
        account: account,
        inbox: inbox,
        conversation: campaign_conversation,
        message_type: :outgoing,
        created_at: 10.minutes.ago
      )

      result = described_class.new(account: account, inbox: inbox, audience: audience).call

      expect(result[:deliverable_count]).to eq(1)
      expect(result[:totals]['deliverable']).to eq(1)
      expect(result[:sample_contacts].first[:reason]).to eq('deliverable')
    end

    it 'treats telegram bot contacts with stored targets as deliverable' do
      channel = create(:channel_telegram, account: account)
      inbox = channel.inbox
      contact = create(:contact, account: account, additional_attributes: { 'social_telegram_user_id' => '7788' })
      contact.label_list.add(label.title)
      contact.save!

      result = described_class.new(account: account, inbox: inbox, audience: audience).call

      expect(result[:deliverable_count]).to eq(1)
      expect(result[:totals]['deliverable']).to eq(1)
      expect(result[:sample_contacts].first[:target_identifier]).to eq('7788')
    end

    it 'blocks tiktok contacts outside the reply window when the stored conversation target has no active window' do
      channel = create(:channel_tiktok, account: account)
      inbox = channel.inbox
      contact = create(:contact, account: account)
      contact.label_list.add(label.title)
      contact.save!
      create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'tt-conv-1')

      result = described_class.new(account: account, inbox: inbox, audience: audience).call

      expect(result[:deliverable_count]).to eq(0)
      expect(result[:totals]['outside_reply_window']).to eq(1)
      expect(result[:sample_contacts].first[:reason]).to eq('outside_reply_window')
      expect(result[:sample_contacts].first[:target_identifier]).to eq('tt-conv-1')
    end

    it 'treats twitter contacts as deliverable only when a direct-message thread exists' do
      channel = create(:channel_twitter_profile, account: account)
      inbox = create(:inbox, account: account, channel: channel)
      contact = create(:contact, account: account)
      contact.label_list.add(label.title)
      contact.save!
      contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'tw-user-1')
      create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        additional_attributes: { type: 'direct_message' }
      )

      result = described_class.new(account: account, inbox: inbox, audience: audience).call

      expect(result[:deliverable_count]).to eq(1)
      expect(result[:totals]['deliverable']).to eq(1)
      expect(result[:sample_contacts].first[:target_identifier]).to eq('tw-user-1')
    end
  end
end
