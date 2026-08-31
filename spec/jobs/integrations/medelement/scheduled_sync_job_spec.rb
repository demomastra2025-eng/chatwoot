require 'rails_helper'

RSpec.describe Integrations::Medelement::ScheduledSyncJob do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account, status: 'enabled') }
  let(:launcher) { instance_double(Integrations::Medelement::ScheduledSyncLauncher, perform: true) }

  before do
    account.enable_features!('scheduling')
    allow(Integrations::Medelement::ScheduledSyncLauncher).to receive(:new).and_return(launcher)
  end

  it 'dispatches enabled hook phases through the durable launcher' do
    described_class.perform_now(hook.id, %w[receptions])

    expect(Integrations::Medelement::ScheduledSyncLauncher).to have_received(:new).with(
      hook: hook,
      phases: %w[receptions]
    )
    expect(launcher).to have_received(:perform)
  end

  it 'does not dispatch a disabled hook' do
    hook.update!(status: 'disabled')

    described_class.perform_now(hook.id, %w[receptions])

    expect(Integrations::Medelement::ScheduledSyncLauncher).not_to have_received(:new)
  end
end
