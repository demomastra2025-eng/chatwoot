require 'rails_helper'

RSpec.describe Whatsapp::RecordUsageDeliveryService do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, account: account, phone_number: '+77010000003', provider: 'whatsapp_cloud',
                              sync_templates: false, validate_provider_config: false)
  end
  let(:message) do
    create(:message, account: account, inbox: channel.inbox, message_type: :outgoing, status: :read,
                     source_id: 'wamid.usage-1')
  end
  let(:status) do
    {
      id: 'wamid.usage-1', status: 'delivered', timestamp: Time.current.to_i.to_s,
      recipient_id: '+77011234567',
      pricing: { category: 'service', type: 'regular', pricing_model: 'PMP', billable: false },
      conversation: { origin: { type: 'service' } }
    }.with_indifferent_access
  end

  it 'records the delivery once by canonical phone and provider id, including explicit billable false' do
    2.times do
      described_class.new(inbox: channel.inbox, message: message, status: status).perform
    end

    record = WhatsappUsageDelivery.find_by!(phone_number: '77010000003', provider_message_id: 'wamid.usage-1')
    expect(WhatsappUsageDelivery.count).to eq(1)
    expect(record).to have_attributes(
      account_id: account.id,
      message_id: message.id,
      category: 'service',
      pricing_type: 'regular',
      pricing_model: 'PMP',
      billable: false,
      conversation_origin_type: 'service',
      recipient_country: 'KZ'
    )
    expect(record.delivered_at.to_i).to eq(status[:timestamp].to_i)
  end

  it 'keeps a delivered event without its timestamp as unknown until an exact retry arrives' do
    missing_timestamp = status.except(:timestamp)
    described_class.new(inbox: channel.inbox, message: message, status: missing_timestamp).perform
    first_record = WhatsappUsageDelivery.find_by!(provider_message_id: 'wamid.usage-1')
    expect(first_record.delivered_at).to be_nil

    described_class.new(inbox: channel.inbox, message: message, status: status).perform

    expect(WhatsappUsageDelivery.count).to eq(1)
    expect(first_record.reload.delivered_at.to_i).to eq(status[:timestamp].to_i)
  end

  it 'fills a missing recipient country from a later status retry without creating a duplicate' do
    described_class.new(inbox: channel.inbox, message: message, status: status.except(:recipient_id)).perform
    record = WhatsappUsageDelivery.find_by!(phone_number: '77010000003', provider_message_id: 'wamid.usage-1')
    expect(record.recipient_country).to be_nil

    described_class.new(inbox: channel.inbox, message: message, status: status).perform

    expect(WhatsappUsageDelivery.count).to eq(1)
    expect(record.reload.recipient_country).to eq('KZ')
  end

  it 'normalizes Meta authentication international webhook category to the canonical catalog category' do
    international_status = status.deep_dup
    international_status[:pricing][:category] = 'authentication_international'
    international_status[:pricing][:billable] = true

    described_class.new(inbox: channel.inbox, message: message, status: international_status).perform

    expect(WhatsappUsageDelivery.find_by!(provider_message_id: 'wamid.usage-1')).to have_attributes(
      category: 'authentication-international',
      billable: true
    )
  end

  it 'treats read-before-delivered as delivery evidence without using the read time as the delivery time' do
    read_status = status.merge(status: 'read', timestamp: Time.current.to_i.to_s)
    described_class.new(inbox: channel.inbox, message: message, status: read_status).perform
    first_record = WhatsappUsageDelivery.find_by!(provider_message_id: 'wamid.usage-1')
    expect(first_record.delivered_at).to be_nil

    described_class.new(inbox: channel.inbox, message: message, status: status).perform

    expect(WhatsappUsageDelivery.count).to eq(1)
    expect(first_record.reload.delivered_at.to_i).to eq(status[:timestamp].to_i)
  end

  it 'excludes Business App echoes, imported history, private notes, and inbound messages' do
    [
      { external_echo: true },
      { imported_history: true },
      { private: true, message_type: :outgoing },
      { private: false, message_type: :incoming }
    ].each_with_index do |attributes, index|
      content_attributes = attributes.slice(:external_echo, :imported_history)
      candidate = create(
        :message,
        account: account,
        inbox: channel.inbox,
        message_type: attributes[:message_type] || :outgoing,
        private: attributes[:private] || false,
        content_attributes: content_attributes,
        source_id: "wamid.excluded-#{index}"
      )

      excluded_status = status.merge(id: candidate.source_id)
      described_class.new(inbox: channel.inbox, message: candidate, status: excluded_status).perform
    end

    expect(WhatsappUsageDelivery.count).to eq(0)
  end

  it 'does not record WhatsApp Web deliveries' do
    web_channel = create(:channel_whatsapp_web, account: account, skip_provisioning: true)
    web_message = create(:message, account: account, inbox: web_channel.inbox, message_type: :outgoing,
                                   source_id: 'wamid.web')

    described_class.new(inbox: web_channel.inbox, message: web_message, status: status.merge(id: 'wamid.web')).perform

    expect(WhatsappUsageDelivery.count).to eq(0)
  end
end
