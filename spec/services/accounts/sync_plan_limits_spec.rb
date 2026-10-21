# frozen_string_literal: true

require 'rails_helper'

# «Обновить лимиты по тарифу»: the numbers of the plan, as they are now, go into the limits that follow the plan, and nothing else
# changes (Accounts::SyncPlanLimits).
RSpec.describe Accounts::SyncPlanLimits do
  let(:account) { create(:account) }
  let(:actor) { create(:super_admin) }
  let(:max) { ChatwootApp.max_limit }
  let(:marks_key) { Accounts::LimitSettings::KEY }
  let(:service) { described_class.new(account: account, actor: actor) }

  # The file of the plans, with numbers of its own
  def plan_with(numbers)
    allow(Accounts::Plans).to(receive(:limits_for).and_wrap_original { |original, *args| original.call(*args).merge(numbers) })
  end

  def apply_plan!(modules: [])
    Accounts::ApplyPlan.new(account: account, modules: modules).call
  end

  def choose(marks)
    account.update!(custom_attributes: account.custom_attributes.to_h.merge(marks_key => marks))
  end

  def audits = Audited::Audit.where(auditable_type: 'Account', auditable_id: account.id, action: described_class::AUDIT_ACTION)

  before do
    GlobalConfig.clear_cache
    plan_with('conversations' => 2000, 'agents' => 10)
    apply_plan!
    plan_with('conversations' => 3000, 'agents' => 12, 'emails' => 100)
  end

  describe '#preview' do
    it 'says which limits get which number, with what applied before, and writes nothing' do
      diff = service.preview

      expect(diff.plan_assigned).to be(true)
      expect(diff).to be_changed
      expect(diff.limits).to eq(
        'agents' => { 'from' => 10, 'to' => 12 },
        'conversations' => { 'from' => 2000, 'to' => 3000 },
        'emails' => { 'from' => nil, 'to' => 100 }
      )
      expect(diff.before).to eq('agents' => 10, 'conversations' => 2000, 'emails' => nil)
      expect(account.reload.limits).to include('agents' => 10, 'conversations' => 2000)
      expect(audits).to be_empty
    end

    it 'names the limits chosen by hand that stay and differ from the plan, and the ones a trial holds' do
      account.update!(limits: account.limits.merge('agents' => 3))
      choose('agents' => 3)

      expect(service.preview.kept).to eq(['agents'])

      account.reload.activate_trial!(3)
      account.expire_trial!

      expect(described_class.new(account: account.reload).preview.held).to eq(%w[inboxes])
    end

    it 'has nothing to change when every limit already is the number of the plan' do
      service.call

      diff = described_class.new(account: account.reload).preview

      expect(diff).not_to be_changed
      expect(diff.limits).to eq({})
    end

    it 'has nothing to follow for an account without a plan' do
      other = create(:account)

      diff = described_class.new(account: other).preview

      expect(diff.plan_assigned).to be(false)
      expect(diff).not_to be_changed
    end

    it 'reads the plan the account has (its modules), not another one' do
      allow(Accounts::Plans).to receive(:limits_for).and_wrap_original do |original, modules|
        original.call(modules).merge('conversations' => (modules.include?('ai_agents') ? 5000 : 3000))
      end

      expect(service.preview.limits['conversations']['to']).to eq(3000)

      apply_plan!(modules: %w[ai_agents])

      expect(described_class.new(account: account.reload).preview.limits).to eq({}) # applied with the modules: nothing left to move
    end
  end

  describe '#call' do
    it 'writes the numbers of the plan into the limits that follow it' do
      service.call

      expect(account.reload.limits).to include('agents' => 12, 'conversations' => 3000, 'emails' => 100)
    end

    it 'remembers the numbers it wrote, so a later number of the plan is still told from a number somebody typed' do
      service.call

      expect(account.reload.custom_attributes[Accounts::LimitSettings::PLAN_NUMBERS_KEY]).to include('agents' => 12, 'conversations' => 3000)
      plan_with('agents' => 15)
      settings = Accounts::LimitSettings.new(account.reload)
      expect(settings.source('agents')).to eq(:plan)
      expect(settings.plan_value('agents')).to eq(15)
    end

    it 'leaves «своё число» and «без ограничений» as they are' do
      account.update!(limits: account.limits.merge('agents' => 3, 'conversations' => max))
      choose('agents' => 3, 'conversations' => 'unlimited')

      diff = service.call

      expect(diff.limits.keys).to eq(['emails'])
      expect(account.reload.limits).to include('agents' => 3, 'conversations' => max, 'emails' => 100)
      expect(account.custom_attributes[marks_key]).to eq('agents' => 3, 'conversations' => 'unlimited')
    end

    it 'leaves a limit the plan has no number for as it is, even a number somebody wrote' do
      account.update!(limits: account.limits.merge('inboxes' => 7))

      service.call

      expect(account.reload.limits['inboxes']).to eq(7)
    end

    it 'does not touch the functions, the modules, the fine tuning or the plan attributes' do
      account.enable_features('sla')
      account.disable_features('macros')
      account.save!
      features = account.reload.enabled_features
      plan = account.custom_attributes.slice(*%w[plan plan_modules plan_version plan_applied_at])

      service.call

      expect(account.reload.enabled_features).to eq(features)
      expect(account.custom_attributes).to include(plan)
    end

    it 'leaves the zero an ended trial put on a limit, which only the plan gives back' do
      account.update!(limits: account.limits.merge('inboxes' => 6))
      account.reload.activate_trial!(3)
      account.expire_trial!
      plan_with('conversations' => 3000, 'agents' => 12, 'inboxes' => 4)

      described_class.new(account: account.reload, actor: actor).call

      expect(account.reload.limits).to include('inboxes' => 0, 'agents' => 0, 'conversations' => 3000)
    end

    it 'writes nothing and logs nothing for an account that is in step' do
      service.call
      account.reload
      version = account.updated_at

      diff = described_class.new(account: account, actor: actor).call

      expect(diff).not_to be_changed
      expect(account.reload.updated_at).to eq(version)
      expect(audits.count).to eq(1)
    end

    it 'writes nothing and logs nothing for an account without a plan' do
      other = create(:account, limits: { 'agents' => 5 })

      diff = described_class.new(account: other, actor: actor).call

      expect(diff.plan_assigned).to be(false)
      expect(other.reload.limits).to eq('agents' => 5)
      expect(Audited::Audit.where(auditable_type: 'Account', auditable_id: other.id, action: described_class::AUDIT_ACTION)).to be_empty
    end

    it 'reads the account again under its lock: what changed meanwhile is judged as it is now' do
      stale = Account.find(account.id)
      account.update!(limits: account.limits.merge('conversations' => 3000))

      diff = described_class.new(account: stale, actor: actor).call

      expect(diff.limits.keys).to match_array(%w[agents emails])
      expect(account.reload.limits).to include('conversations' => 3000, 'agents' => 12)
    end
  end

  describe 'the entry of the audit log' do
    it 'is one per account, written by the actor, with the numbers that were written' do
      service.call

      audit = audits.sole
      expect(audit.user).to eq(actor)
      expect(audit.audited_changes['limits']).to eq(
        'agents' => { 'from' => 10, 'to' => 12 }, 'conversations' => { 'from' => 2000, 'to' => 3000 }, 'emails' => { 'from' => nil, 'to' => 100 }
      )
    end

    it 'carries what a bulk action adds to it' do
      described_class.new(account: account, actor: actor).with_audit_extra('bulk' => true).call

      expect(audits.sole.audited_changes).to include('bulk' => true)
    end
  end
end
