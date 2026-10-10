require 'rails_helper'

RSpec.describe Crm::Appointments::DeliveryPolicy do
  let(:deal) { create(:crm_deal) }

  before { allow(described_class).to receive(:current).and_return(nil) }

  it 'clears a persisted test policy on an ordinary appointment mutation even with a stale deal association' do
    stale = Crm::Deal.find(deal.id)
    deal.update!(appointment_automation_state: { 'playground_run_policy' => { 'token' => 'tainted' } })
    described_class.stamp!(stale)

    expect(deal.reload.appointment_automation_state).not_to have_key('playground_run_policy')
  end

  it 'removes a persisted null policy on an ordinary mutation while preserving other automation state' do
    deal.update!(appointment_automation_state: { 'playground_run_policy' => nil, 'last_evaluated_on' => '2026-10-10' })
    described_class.stamp!(deal)

    expect(deal.reload.appointment_automation_state).to eq('last_evaluated_on' => '2026-10-10')
  end

  it 'stamps a trusted current policy on linked appointment mutations and omits it from public deal data' do
    policy = { 'token' => 'signed-or-tainted-token' }
    allow(described_class).to receive(:current).and_return(policy)
    create(:scheduling_appointment, account: deal.account, crm_deal: deal)

    expect(deal.reload.appointment_automation_state['playground_run_policy']).to eq(policy)
    expect(Crm::PayloadBuilder.deal(deal)[:appointment_automation_state]).not_to have_key('playground_run_policy')
  end

  it 'retains any nonnil causal policy including false instead of falling back to ordinary delivery' do
    helper = Class.new do
      def self.with(_policy)
        yield
      end
    end
    stub_const('Outbound::PlaygroundDeliveryPolicy', helper)
    allow(helper).to receive(:with).and_yield
    allow(described_class).to receive(:current).and_return(false)
    described_class.with(deal) { true }

    expect(helper).to have_received(:with).with(false)
  end

  it 'uses the latest native state for a newly scheduled day check' do
    policy = { 'token' => 'stored-test-policy' }
    deal.update!(appointment_automation_state: { 'playground_run_policy' => policy })
    helper = Class.new do
      def self.with(_policy)
        yield
      end
    end
    stub_const('Outbound::PlaygroundDeliveryPolicy', helper)
    allow(helper).to receive(:with).and_yield
    described_class.with(deal) { true }

    expect(helper).to have_received(:with).with(policy)
  end

  it 'keeps a persisted null causal stamp guarded during a newly scheduled day check' do
    deal.update!(appointment_automation_state: { 'playground_run_policy' => nil })
    helper = Class.new do
      def self.with(_policy)
        yield
      end
    end
    stub_const('Outbound::PlaygroundDeliveryPolicy', helper)
    allow(helper).to receive(:with).and_yield
    described_class.with(deal) { true }

    expect(helper).to have_received(:with).with({})
  end
end
