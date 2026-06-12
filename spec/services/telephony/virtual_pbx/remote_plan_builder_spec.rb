require 'rails_helper'

RSpec.describe Telephony::VirtualPbx::RemotePlanBuilder do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:service) { Telephony::VirtualPbx::ProvisioningService.new(account: account, current_user: admin) }
  let(:base_payload) do
    {
      provider_kind: 'sipuni',
      channel_name: 'Sipuni external line',
      display_phone_number: '+17705550999',
      provider_account_number: '056124100014',
      ingress_number: '056124100014',
      connection: { host: 'ats01.kz.sipuni.com', port: 5060, transport: 'udp', username: '056124100014', password: 'do-not-return' }
    }
  end

  it 'builds a sanitized local-only create plan with no execution' do
    result = service.create_channel(base_payload, dry_run: false)
    state = Telephony::VirtualPbx::DesiredStateBuilder.new(account: account).for_inbox(result.dig(:ui_config, :inbox_id))

    plan = described_class.new(account: account).build(operation: 'create', desired_state: state)

    expect(plan).to include(status: 'dry_run_valid', remote_mutations: 'blocked')
    expect(plan.fetch(:operations).map { |operation| operation[:key] }).to include(
      'upsert_credentials', 'upsert_trunk', 'upsert_number', 'update_number_route'
    )
    expect(plan.fetch(:operations)).to all(include(risk: 'requires_approval'))
    expect(plan.to_json).not_to include('do-not-return')
  end

  it 'blocks normal remote operations for legacy/unowned resources' do
    voice_channel = create(
      :channel_voice,
      :fonoster,
      account: account,
      phone_number: '+17705550123',
      provider_config: {
        number_ref: 'legacy-number',
        provider_kind: 'sipuni',
        display_phone_number: '+17705550123',
        ingress_number: '056124100014',
        operator_agent_aor: 'sip:100@operator.example.test'
      }
    )
    state = Telephony::VirtualPbx::DesiredStateBuilder.new(account: account).for_inbox(voice_channel.inbox.id)

    plan = described_class.new(account: account).build(operation: 'update', desired_state: state)

    expect(plan).to include(status: 'requires_manual_reconcile')
    expect(plan.fetch(:operations)).to all(include(risk: 'blocked'))
    expect(plan.fetch(:operations).first[:conflict]).to include('legacy')
  end
end
