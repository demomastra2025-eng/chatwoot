require 'rails_helper'

RSpec.describe Whatsapp::ManagerUsageBreakdownService do
  let(:account) { create(:account) }
  let(:exchange_rate) { instance_double(WhatsappUsageExchangeRate, rate_per_usd: BigDecimal(500)) }
  let(:channel) do
    create(:channel_whatsapp, account: account, phone_number: '+77010000010', provider: 'whatsapp_cloud',
                              sync_templates: false, validate_provider_config: false)
  end
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account, phone_number: '+77021112233') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '77021112233') }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:manager_a) { create(:user, account: account, name: 'Айганым') }
  let(:manager_b) { create(:user, account: account, name: 'Жасмин') }
  let(:period_start) { Time.utc(2026, 10, 1) }
  let(:period_end) { Time.utc(2026, 11, 1) }

  def create_agent_message_with_delivery(sender:, created_at:, billable:, category: 'service')
    msg = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: sender,
      message_type: :outgoing,
      private: false,
      created_at: created_at
    )
    WhatsappUsageDelivery.create!(
      account_id: account.id,
      phone_number: '77010000010',
      provider_message_id: "wamid.#{msg.id}",
      inbox_id: inbox.id,
      message_id: msg.id,
      delivered_at: created_at + 1.second,
      received_at: created_at + 2.seconds,
      category: category,
      billable: billable,
      recipient_country: 'KZ'
    )
    msg
  end

  it 'calculates manager message counts, consecutive double messages (< 5m), and KZT + VAT overpayment' do
    base_time = period_start + 2.hours

    # Incoming customer message
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: contact,
                     message_type: :incoming, private: false, created_at: base_time)

    # Manager A sends 3 messages in a row within 2 minutes (1st is normal reply, 2nd & 3rd are consecutive!)
    create_agent_message_with_delivery(sender: manager_a, created_at: base_time + 10.seconds, billable: true)
    create_agent_message_with_delivery(sender: manager_a, created_at: base_time + 25.seconds, billable: true)
    create_agent_message_with_delivery(sender: manager_a, created_at: base_time + 90.seconds, billable: true)

    # Manager B sends 1 message after 10 minutes
    create_agent_message_with_delivery(sender: manager_b, created_at: base_time + 10.minutes, billable: false)

    result = described_class.new(
      account: account,
      period_start: period_start,
      period_end: period_end,
      exchange_rate: exchange_rate
    ).perform

    # KZ service rate = $0.018 * 500 = 9.0 KZT per paid message; with 12% VAT = 10.08 KZT per paid message
    expect(result[:consecutive_summary]).to eq(
      window_seconds: 300,
      consecutive_service_count: 2,
      chargeable_consecutive_count: 2,
      consecutive_ratio_percent: 50.0,
      estimated_overpayment_kzt: BigDecimal('18.0'),
      estimated_overpayment_with_vat_kzt: BigDecimal('20.16')
    )

    expect(result[:managers].first).to include(
      user_id: manager_a.id,
      name: 'Айганым',
      delivered_count: 3,
      service_delivered_count: 3,
      chargeable_count: 3,
      free_count: 0,
      consecutive_count: 2,
      chargeable_consecutive_count: 2,
      consecutive_ratio_percent: 66.7,
      estimated_amount_kzt: BigDecimal('27.0'),
      estimated_amount_with_vat_kzt: BigDecimal('30.24'),
      consecutive_overpayment_kzt: BigDecimal('18.0'),
      consecutive_overpayment_with_vat_kzt: BigDecimal('20.16')
    )
  end
end
