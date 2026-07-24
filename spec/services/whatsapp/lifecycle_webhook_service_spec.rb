require 'rails_helper'

RSpec.describe Whatsapp::LifecycleWebhookService do
  let(:channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      validate_provider_config: false,
      sync_templates: false
    )
  end

  def lifecycle_params(field:, value:, time: 1_751_247_548)
    {
      object: 'whatsapp_business_account',
      entry: [{
        id: channel.provider_config['business_account_id'],
        time: time,
        changes: [{ field: field, value: value }]
      }]
    }.with_indifferent_access
  end

  it 'updates a template status immediately and schedules an authoritative sync' do
    channel.update!(
      message_templates: [{
        'id' => '1689556908129832',
        'name' => 'order_confirmation',
        'language' => 'en-US',
        'status' => 'PENDING',
        'category' => 'MARKETING'
      }]
    )
    params = lifecycle_params(
      field: 'message_template_status_update',
      value: {
        event: 'APPROVED',
        message_template_id: 1_689_556_908_129_832,
        message_template_name: 'order_confirmation',
        message_template_language: 'en-US',
        message_template_category: 'UTILITY',
        reason: 'NONE'
      }
    )

    expect do
      expect(described_class.new(channel: channel, field: 'message_template_status_update', params: params).perform)
        .to eq(:processed)
    end.to have_enqueued_job(Channels::Whatsapp::TemplatesSyncJob).with(channel)

    template = channel.reload.message_templates.first
    expect(template).to include('status' => 'APPROVED', 'category' => 'UTILITY', 'reason' => 'NONE')
    expect(channel.provider_config.dig('meta_webhook_lifecycle', 'counters', 'message_template_status_update')).to eq(1)
  end

  it 'does not let an older template lifecycle event overwrite a newer provider state' do
    channel.update!(
      message_templates: [{
        'id' => '1689556908129832',
        'name' => 'order_confirmation',
        'language' => 'en-US',
        'status' => 'PENDING'
      }]
    )
    newer = lifecycle_params(
      field: 'message_template_status_update',
      value: {
        event: 'APPROVED', message_template_id: 1_689_556_908_129_832,
        message_template_name: 'order_confirmation', message_template_language: 'en-US'
      }
    )
    older = newer.deep_dup
    newer[:entry][0][:time] = 1_700_000_200
    older[:entry][0][:time] = 1_700_000_100
    older[:entry][0][:changes][0][:value][:event] = 'REJECTED'

    expect(described_class.new(channel: channel, field: 'message_template_status_update', params: newer).perform).to eq(:processed)
    expect(described_class.new(channel: channel, field: 'message_template_status_update', params: older).perform).to eq(:stale)

    template = channel.reload.message_templates.first
    expect(template).to include('status' => 'APPROVED')
    expect(template.dig('lifecycle_event_versions', 'message_template_status_update')).to include(
      'provider_timestamp' => 1_700_000_200
    )
    expect(enqueued_jobs.count { |job| job[:job] == Channels::Whatsapp::TemplatesSyncJob }).to eq(1)
  end

  it 'deduplicates repeated lifecycle deliveries durably' do
    channel.update!(
      message_templates: [{
        'id' => '806312974732579',
        'name' => 'welcome_template',
        'language' => 'en-US',
        'quality_score' => 'GREEN'
      }]
    )
    params = lifecycle_params(
      field: 'message_template_quality_update',
      value: {
        previous_quality_score: 'GREEN',
        new_quality_score: 'YELLOW',
        message_template_id: 806_312_974_732_579,
        message_template_name: 'welcome_template',
        message_template_language: 'en-US'
      }
    )
    service = described_class.new(channel: channel, field: 'message_template_quality_update', params: params)

    expect(service.perform).to eq(:processed)
    expect(described_class.new(channel: channel, field: 'message_template_quality_update', params: params).perform).to eq(:duplicate)

    state = channel.reload.provider_config.fetch('meta_webhook_lifecycle')
    expect(state['recent_fingerprints'].size).to eq(1)
    expect(state.dig('counters', 'message_template_quality_update')).to eq(1)
    expect(channel.message_templates.first['quality_score']).to eq('YELLOW')
    expect(enqueued_jobs.count { |job| job[:job] == Channels::Whatsapp::TemplatesSyncJob }).to eq(1)
  end

  it 'stores WhatsApp marketing stop and resume preferences on the contact' do
    contact = create(:contact, account: channel.account)
    create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '16505551234')
    params = lifecycle_params(
      field: 'user_preferences',
      value: {
        user_preferences: [{
          wa_id: '16505551234',
          detail: 'User requested to stop marketing messages',
          category: 'marketing_messages',
          value: 'stop',
          timestamp: 1_731_705_721
        }]
      }
    )

    expect(described_class.new(channel: channel, field: 'user_preferences', params: params).perform).to eq(:processed)

    stored_preference = contact.reload.additional_attributes['whatsapp_marketing_preference']
    expect(stored_preference).to include(
      'value' => 'stop',
      'timestamp' => 1_731_705_721,
      'channel_id' => channel.id
    )
    expect(stored_preference['event_fingerprints'].size).to eq(1)
  end
end
