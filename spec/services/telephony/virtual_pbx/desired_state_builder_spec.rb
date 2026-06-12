require 'rails_helper'

RSpec.describe Telephony::VirtualPbx::DesiredStateBuilder do
  let(:account) { create(:account) }
  let(:service) do
    Telephony::VirtualPbx::ProvisioningService.new(
      account: account,
      current_user: create(:user, account: account, role: :administrator)
    )
  end
  let(:payload) do
    {
      provider_kind: 'sipuni',
      channel_name: 'Sipuni external line',
      display_phone_number: '+17705550999',
      provider_account_number: '056124100014',
      ingress_number: '056124100014',
      connection: {
        host: 'ats01.kz.sipuni.com',
        port: 5060,
        transport: 'udp',
        username: '056124100014',
        password: 'do-not-return-this-secret'
      }
    }
  end

  it 'builds a canonical business desired state with ownership metadata and no raw secrets' do
    result = service.create_channel(payload, dry_run: false)
    inbox = Inbox.find(result.dig(:ui_config, :inbox_id))

    state = described_class.new(account: account).for_inbox(inbox.id)

    expect(state).to include(
      account_id: account.id,
      inbox_id: inbox.id,
      provider_kind: 'sipuni',
      managed_by: 'onelink'
    )
    expect(state.dig(:phone_numbers, :display_phone_number)).to eq('+17705550999')
    expect(state.dig(:phone_numbers, :ingress_number)).to eq('056124100014')
    expect(state.dig(:ownership, :onelink_account_id)).to eq(account.id)
    expect(state.dig(:ownership, :onelink_inbox_id)).to eq(inbox.id)
    expect(state.dig(:connection, :password_configured)).to be(true)
    expect(state.to_json).not_to include('do-not-return-this-secret')
  end
end
