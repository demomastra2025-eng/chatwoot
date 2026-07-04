# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::VirtualPbx::ProvisioningService do
  let(:account) { create(:account) }
  let(:operator) { create(:user, account: account, role: :agent) }
  let(:service) { described_class.new(account: account, current_user: operator) }

  it 'deletes contact channel profiles before deleting a managed voice inbox' do
    result = service.create_channel(
      {
        provider_kind: 'sipuni',
        channel_name: 'Sipuni managed line',
        display_phone_number: '+77072890808',
        provider_account_number: '+77072890808',
        ingress_number: '+77072890808',
        connection: {
          host: 'ats01.kz.sipuni.com',
          port: 5060,
          transport: 'udp',
          username: '015856100021',
          password: 'provider-secret'
        },
        profiles: [
          {
            user_id: operator.id,
            internal_extension: '505',
            sip_username: '015856100021',
            sip_password: 'profile-secret',
            enabled: true
          }
        ]
      },
      dry_run: false
    )
    inbox = account.inboxes.find(result.dig(:ui_config, :inbox_id))
    contact = create(:contact, account: account)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '+77056162603')
    contact_channel_profile = create(
      :contact_channel_profile,
      account: account,
      contact: contact,
      inbox: inbox,
      contact_inbox: contact_inbox,
      channel_type: 'Channel::Voice',
      provider: 'sipuni',
      source_id: contact_inbox.source_id
    )

    delete_result = nil
    expect do
      delete_result = service.delete_channel(inbox_id: inbox.id, confirm: true, dry_run: false, remote_commit: false)
    end.to change { ContactChannelProfile.exists?(contact_channel_profile.id) }.from(true).to(false)

    expect(delete_result[:deleted]).to be(true)
    expect(Inbox.exists?(inbox.id)).to be(false)
  end
end
