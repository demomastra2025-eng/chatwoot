# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::ChannelOverrides do
  subject(:service) { described_class.new(account: account, actor: super_admin, request: request) }

  let(:account) { create(:account) }
  let(:super_admin) { create(:super_admin) }
  let(:request) { instance_double(ActionDispatch::Request, remote_ip: '10.0.0.7', request_id: 'req-1') }

  def overrides
    account.reload.custom_attributes['channel_overrides']
  end

  def audits
    Audited::Audit.where(auditable_type: 'Account', auditable_id: account.id, action: described_class::AUDIT_ACTION)
  end

  it 'stores the overrides in the account, without a schema change' do
    changes = service.apply('api' => 'shown', 'telegram_personal' => 'hidden')

    expect(overrides).to eq('api' => 'shown', 'telegram_personal' => 'hidden')
    expect(changes).to eq(
      'api' => { 'from' => nil, 'to' => 'shown' },
      'telegram_personal' => { 'from' => nil, 'to' => 'hidden' }
    )
  end

  it 'keeps the other custom attributes of the clinic' do
    account.update!(custom_attributes: { 'plan' => 'base', 'plan_modules' => ['ai_agents'], 'industry' => 'clinic' })

    service.apply('api' => 'shown')

    expect(account.reload.custom_attributes).to include('plan' => 'base', 'plan_modules' => ['ai_agents'], 'industry' => 'clinic')
  end

  it 'keeps the channels that are not named' do
    service.apply('api' => 'shown', 'sms' => 'shown')

    service.apply('sms' => 'hidden')

    expect(overrides).to eq('api' => 'shown', 'sms' => 'hidden')
  end

  it 'removes the entry when a channel goes back to the platform setting' do
    service.apply('api' => 'shown', 'sms' => 'shown')

    changes = service.apply('api' => 'default')

    expect(changes).to eq('api' => { 'from' => 'shown', 'to' => nil })
    expect(overrides).to eq('sms' => 'shown')
  end

  it 'removes the whole key when the last exception goes' do
    service.apply('api' => 'shown')

    service.apply('api' => 'default')

    expect(account.reload.custom_attributes).not_to have_key('channel_overrides')
  end

  it 'leaves one audit entry with who changed what' do
    service.apply('api' => 'shown')

    audit = audits.sole
    expect(audit).to have_attributes(user_id: super_admin.id, comment: 'super_admin', remote_address: '10.0.0.7')
    expect(audit.audited_changes['channels']).to eq('api' => { 'from' => nil, 'to' => 'shown' })
  end

  it 'writes and audits nothing when nothing changes' do
    service.apply('api' => 'shown')

    expect(service.apply('api' => 'shown', 'website' => 'default')).to eq({})
    expect(audits.count).to eq(1)
  end

  it 'refuses an unknown channel or state before writing anything' do
    expect { service.apply('api' => 'shown', 'ghost' => 'shown') }.to raise_error(described_class::InvalidOverrides, /unknown channel: ghost/)
    expect { service.apply('api' => 'always') }.to raise_error(described_class::InvalidOverrides, /unknown state for api/)
    expect { service.apply('api') }.to raise_error(described_class::InvalidOverrides)

    expect(account.reload.custom_attributes).not_to have_key('channel_overrides')
    expect(audits).to be_empty
  end

  it 'survives applying a plan' do
    service.apply('api' => 'shown')

    Accounts::ApplyPlan.new(account: account, modules: %w[ai_agents]).call

    expect(overrides).to eq('api' => 'shown')
  end
end
