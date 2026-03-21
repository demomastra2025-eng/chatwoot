require 'rails_helper'

RSpec.describe Integrations::Medelement::DispatchJob do
  let(:account) { create(:account) }

  before do
    account.enable_features!('scheduling')
    allow(Integrations::Medelement::SyncJob).to receive(:perform_later)
  end

  it 'enqueues sync jobs for enabled Medelement hooks only' do
    enabled_hook = create(:integrations_hook, :medelement, account: account)
    create(:integrations_hook, :medelement, account: create(:account).tap do |a|
      a.enable_features!('scheduling')
    end, status: Integrations::Hook.statuses[:disabled])

    described_class.perform_now

    expect(Integrations::Medelement::SyncJob).to have_received(:perform_later).with(enabled_hook.id)
    expect(Integrations::Medelement::SyncJob).to have_received(:perform_later).once
  end
end
