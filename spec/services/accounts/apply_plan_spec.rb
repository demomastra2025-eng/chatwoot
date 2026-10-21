# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::ApplyPlan do
  let(:account) { create(:account).tap { |record| record.disable_features!(*Featurable::FEATURE_NAMES) } }
  let(:actor) { create(:super_admin) }
  let(:plans) { Accounts::Plans }

  def service(modules = [], **)
    described_class.new(account: account, modules: modules, actor: actor, **)
  end

  def enabled_flags
    account.reload.enabled_features.keys
  end

  describe '#preview' do
    it 'lists what would be switched on and off and what would change in the limits' do
      account.enable_features!('captain_scheduling_grounding_guard', 'campaigns', 'crm')

      preview = service(%w[ai_agents]).preview

      expect(preview).to have_attributes(
        plan: 'base', modules: %w[ai_agents], plan_version: Accounts::Plans.version, previous_plan: nil, previous_modules: []
      )
      expect(preview.enable).to include('channel_email', 'channel_voice', 'captain_integration', 'labels')
      expect(preview.enable).not_to include('crm')
      expect(preview.disable).to contain_exactly('captain_scheduling_grounding_guard', 'campaigns')
      expect(preview.limits).to eq(
        'conversations' => { 'from' => nil, 'to' => ChatwootApp.max_limit },
        'non_web_inboxes' => { 'from' => nil, 'to' => ChatwootApp.max_limit }
      )
      expect(preview).to be_changed
    end

    it 'writes nothing: no flags, no limits, no attributes, no audit row' do
      account.enable_features!('captain_scheduling_grounding_guard')
      stored = Account.find(account.id).attributes

      expect { service(%w[ai_agents quality]).preview }.not_to change(Audited::Audit, :count)

      expect(Account.find(account.id).attributes).to eq(stored)
    end

    it 'renders as JSON for the clinic card' do
      json = service(%w[broadcasts]).preview.as_json

      expect(json).to include('plan' => 'base', 'modules' => %w[broadcasts], 'plan_version' => Accounts::Plans.version, 'changed' => true)
      expect(json['previous']).to eq('plan' => nil, 'modules' => [], 'plan_version' => nil)
      expect(json['enable']).to include('campaigns', 'whatsapp_campaign')
      expect(json.keys).to include('disable', 'limits', 'notes')
    end

    it 'reports nothing to change for an account that already has exactly the plan' do
      service(%w[quality]).call

      preview = service(%w[quality]).preview

      expect(preview).not_to be_changed
      expect(preview.enable).to be_empty
      expect(preview.disable).to be_empty
      expect(preview.limits).to be_empty
    end
  end

  describe '#call' do
    it 'switches on the base, the chosen modules and the locked flags' do
      service(%w[ai_agents]).call

      expect(enabled_flags).to include(*plans.base_features, *plans.module_features('ai_agents'), *plans.locked_on)
      expect(enabled_flags).not_to include(*plans.module_features('broadcasts'), *plans.module_features('quality'))
    end

    it 'switches off the modules that are not chosen' do
      account.enable_features!('campaigns', 'sla', 'custom_tools')

      service(%w[quality]).call

      expect(enabled_flags).to include('sla')
      expect(enabled_flags).not_to include('campaigns', 'custom_tools')
    end

    it 'switches the never_enabled flags off, including the deprecated ones' do
      account.enable_features!('captain_scheduling_grounding_guard', 'custom_roles', 'saml', 'channel_twitter', 'contact_chatwoot_support_team')

      service(plans.module_keys).call

      expect(enabled_flags).not_to include(*plans.never_enabled)
    end

    it 'keeps the internal flags exactly as the account has them' do
      account.enable_features!('ip_lookup', 'communication_threads', 'assignment_v2')

      service(%w[ai_agents]).call

      expect(enabled_flags).to include('ip_lookup', 'communication_threads', 'assignment_v2')
      expect(enabled_flags).not_to include('linear_integration', 'inbox_view')
    end

    it 'writes the numbers of the plan and leaves the keys the plan keeps null untouched' do
      account.update!(limits: { 'agents' => 7, 'storage_bytes' => 5_000 })

      service.call

      expect(account.reload.limits).to eq(
        'agents' => 7, 'storage_bytes' => 5_000, 'conversations' => ChatwootApp.max_limit, 'non_web_inboxes' => ChatwootApp.max_limit
      )
    end

    it 'lets the account keep its own limits: the plan only fills the blanks' do
      account.update!(limits: { 'conversations' => 10 })

      service.call

      expect(account.reload.limits).to eq('conversations' => 10, 'non_web_inboxes' => ChatwootApp.max_limit)
    end

    it 'stores the plan, its modules, its version and the moment it was applied in Astana time' do
      account.update!(custom_attributes: { 'industry' => 'clinic' })

      service(%w[broadcasts ai_agents]).call

      expect(account.reload.custom_attributes).to include(
        'industry' => 'clinic', 'plan' => 'base', 'plan_modules' => %w[ai_agents broadcasts], 'plan_version' => Accounts::Plans.version
      )
      expect(account.custom_attributes['plan_applied_at']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+05:00\z/)
    end

    it 'takes a module back when the next application does not choose it' do
      service(%w[ai_agents broadcasts]).call
      service(%w[broadcasts]).call

      expect(enabled_flags).to include('campaigns')
      expect(enabled_flags).not_to include('captain_integration', 'captain_tasks')
      expect(account.custom_attributes['plan_modules']).to eq(%w[broadcasts])
    end

    it 'is repeatable: the second application changes no flag' do
      service(%w[quality]).call
      second = service(%w[quality]).call

      expect(second.enable).to be_empty
      expect(second.disable).to be_empty
    end

    it 'leaves the trial exactly as it is and says so' do
      account.activate_trial!(3)
      trial_state = account.reload.custom_attributes.slice('plan_type', 'trial_expires_at', 'trial_snapshot')

      diff = service.call

      expect(account.reload.custom_attributes).to include(trial_state)
      expect(account.custom_attributes['plan']).to eq('base')
      expect(diff.notes).to eq(%w[trial_active trial_locks_limits])
    end

    it 'does not warn about the limits when the trial a super admin started will keep them once the plan is applied' do
      account.activate_trial!(3, keep_limits: true)

      expect(account.trial_locks_limits?).to be(true) # the clinic has no plan yet ...
      expect(service.preview.notes).to eq(['trial_active']) # ... but the preview asks for the moment after it has one
    end

    it 'tells that an ended trial holds the operator and channel limits at zero, and that the plan gives them back' do
      account.activate_trial!(3)
      account.expire_trial!

      expect(service.preview.notes).to eq(['trial_limits_restored'])
      service.call
      expect(account.reload.limits).not_to include('agents', 'inboxes')
    end

    it 'does not claim zero limits for an ended trial of a clinic that had a plan, which kept its limits' do
      account.update!(limits: { 'agents' => 7 })
      service.call
      account.activate_trial!(3, keep_limits: true)
      account.expire_trial!

      expect(service.preview.notes).to eq([])
      expect(account.reload.limits).to include('agents' => 7)
    end

    it 'does not blame the trial for a zero limit the clinic was given on purpose after a trial that kept its limits' do
      service.call
      account.activate_trial!(3, keep_limits: true)
      account.expire_trial!
      account.update!(limits: account.limits.merge('inboxes' => 0))

      expect(service.preview.notes).to eq([])
    end

    it 'writes one audit entry with the actor, before and after' do
      account.enable_features!('captain_scheduling_grounding_guard')

      expect { service(%w[ai_agents]).call }.to change { Audited::Audit.where(action: 'apply_plan').count }.by(1)

      audit = Audited::Audit.where(action: 'apply_plan').last
      expect(audit).to have_attributes(auditable_id: account.id, associated_id: account.id, user_id: actor.id, comment: 'super_admin')
      expect(audit.audited_changes).to include(
        'before' => { 'plan' => nil, 'plan_modules' => [], 'plan_version' => nil },
        'after' => { 'plan' => 'base', 'plan_modules' => %w[ai_agents], 'plan_version' => Accounts::Plans.version }
      )
      expect(audit.audited_changes['features']['enabled']).to include('crm', 'captain_integration')
      expect(audit.audited_changes['features']['disabled']).to eq(%w[captain_scheduling_grounding_guard])
      expect(audit.audited_changes['limits']).to include('conversations' => { 'from' => nil, 'to' => ChatwootApp.max_limit })
    end

    it 'marks a change by the platform itself as a system entry' do
      described_class.new(account: account, modules: []).call

      expect(Audited::Audit.where(action: 'apply_plan').last).to have_attributes(user_id: nil, comment: 'system')
    end

    it 'writes nothing, not even an audit row, when the account cannot be saved' do
      allow(account).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)
      stored = Account.find(account.id).attributes

      expect { service(%w[ai_agents]).call }.to raise_error(ActiveRecord::RecordInvalid)

      expect(Account.find(account.id).attributes).to eq(stored)
      expect(Audited::Audit.where(action: 'apply_plan')).to be_empty
    end
  end

  describe 'during a running trial' do
    before do
      service.call
      account.activate_trial!(3)
      account.enable_features!('sla')
    end

    it 'does not list the functions the trial granted among the ones to switch off' do
      preview = service.preview

      expect(preview.disable).to eq(%w[sla])
      expect(preview.enable).to be_empty
    end

    it 'resets only what was changed by hand and keeps the functions of the trial on' do
      diff = service.call

      expect(diff.disable).to eq(%w[sla])
      expect(enabled_flags).to include(*plans.module_features('ai_agents'))
      expect(enabled_flags).not_to include('sla')
      expect(Accounts::PlanDrift.call(account)).to eq(extra: [], missing: [])
    end

    it 'does not hold on to the functions of a trial that has ended' do
      account.expire_trial!
      account.enable_features!('captain_integration')

      expect(service.preview.disable).to include('captain_integration', 'sla')
    end

    it 'switches a trial function back on that was switched off by hand, as the drift of the clinic says' do
      account.disable_features!('captain_tasks')

      expect(service.preview.enable).to eq(%w[captain_tasks])
    end
  end

  # The end of a trial that nobody chose for the clinic (self-registration) puts the operator and channel limits at 0 and keeps
  # the earlier values in the snapshot. Applying a plan gives them back by itself, whatever state the trial is in.
  describe 'after a trial' do
    def end_trial!(days: 3)
      account.activate_trial!(days)
      account.expire_trial!
    end

    context 'when the account has never had a trial' do
      it 'restores nothing and says nothing' do
        account.update!(limits: { 'agents' => 0 })

        preview = service.preview

        expect(preview.notes).to eq([])
        expect(preview.limits).not_to include('agents')
        service.call
        expect(account.reload.limits).to include('agents' => 0)
      end
    end

    context 'when the trial is running' do
      it 'restores nothing yet: the limits are locked only when it ends' do
        account.update!(limits: { 'agents' => 5, 'inboxes' => 3 })
        account.activate_trial!(3)

        preview = service.preview

        expect(preview.limits).not_to include('agents', 'inboxes')
        expect(preview.notes).to eq(%w[trial_active trial_locks_limits])
        service.call
        expect(account.reload.limits).to include('agents' => 5, 'inboxes' => 3)
      end

      it 'restores nothing for a trial a super admin started, which keeps the limits' do
        account.update!(limits: { 'agents' => 5 })
        service.call
        account.activate_trial!(3, keep_limits: true)

        expect(service.preview.limits).not_to include('agents')
        expect(service.preview.notes).to eq(['trial_active'])
      end
    end

    context 'when the trial has ended and put the limits at zero' do
      before do
        account.update!(limits: { 'agents' => 5, 'inboxes' => 3, 'conversations' => 200 })
        end_trial!
      end

      it 'shows the old values as the change, in the preview, before anything is written' do
        expect(account.reload.limits).to include('agents' => 0, 'inboxes' => 0)

        preview = service.preview

        expect(preview.limits).to include('agents' => { 'from' => 0, 'to' => 5 }, 'inboxes' => { 'from' => 0, 'to' => 3 })
        expect(preview.notes).to eq(['trial_limits_restored'])
        expect(preview).to be_changed
        expect(account.reload.limits).to include('agents' => 0, 'inboxes' => 0)
      end

      it 'gives the values from before the trial back when the plan is applied, and leaves the other limits alone' do
        service.call

        expect(account.reload.limits).to include('agents' => 5, 'inboxes' => 3)
        # a number the account holds that is not the plan one is its own: the plan leaves it
        expect(account.limits['conversations']).to eq(200)
      end

      it 'writes what it restored into the entry of the audit log' do
        service.call

        audit = Audited::Audit.where(action: 'apply_plan').last
        expect(audit.audited_changes['limits']).to include('agents' => { 'from' => 0, 'to' => 5 }, 'inboxes' => { 'from' => 0, 'to' => 3 })
      end

      it 'is done once: the next application finds nothing to give back' do
        service.call
        second = service.preview

        expect(second.limits).not_to include('agents', 'inboxes')
        expect(second.notes).to eq([])
      end

      it 'lets a number the plan itself sets win over the restored one' do
        allow(plans).to receive(:limits_for).and_return('agents' => 2)

        expect(service.preview.limits).to include('agents' => { 'from' => 0, 'to' => 2 }, 'inboxes' => { 'from' => 0, 'to' => 3 })
        service.call

        expect(account.reload.limits).to include('agents' => 2, 'inboxes' => 3)
      end
    end

    context 'when a plan was applied during the trial and the trial then ended' do
      it 'gives the limits back when the plan is applied again' do
        account.update!(limits: { 'agents' => 5, 'inboxes' => 3 })
        service.call
        account.reload.activate_trial!(3)
        account.expire_trial!
        expect(account.reload.limits).to include('agents' => 0)

        service.call

        expect(account.reload.limits).to include('agents' => 5, 'inboxes' => 3)
      end
    end

    context 'when the account had no limits of its own before the trial' do
      before { end_trial! }

      it 'takes the zero off, so the general value applies again, and keeps the other limits' do
        account.update!(limits: account.limits.merge('conversations' => 10))

        preview = service.preview

        expect(preview.limits).to include('agents' => { 'from' => 0, 'to' => nil }, 'inboxes' => { 'from' => 0, 'to' => nil })
        service.call
        expect(account.reload.limits).not_to include('agents', 'inboxes')
        expect(account.limits).to include('conversations' => 10)
      end
    end

    # The number the limit had before the trial was only the general value of the platform (the default of an account without a
    # plan): it is not written back, the limit holds no number and follows the plan - the number the plan gets later is written to it
    context 'when the number from before the trial was the general value of the platform' do
      before do
        allow(GlobalConfig).to receive(:get).and_call_original
        allow(GlobalConfig).to receive(:get).with('ACCOUNT_AGENTS_LIMIT').and_return('ACCOUNT_AGENTS_LIMIT' => 5)
        account.update!(limits: { 'agents' => 5, 'inboxes' => 3 })
        end_trial!
      end

      it 'takes the key off instead of writing the number back, and writes back a number that is not the general value' do
        preview = service.preview

        expect(preview.limits).to include('agents' => { 'from' => 0, 'to' => nil }, 'inboxes' => { 'from' => 0, 'to' => 3 })
        service.call
        expect(account.reload.limits).not_to have_key('agents')
        expect(account.limits['inboxes']).to eq(3)
        expect(Accounts::LimitSettings.new(account).source('agents')).to eq(:plan)
      end

      it 'writes the number of the plan when it has one (it wins over the restored one)' do
        allow(plans).to receive(:limits_for).and_return('agents' => 2)

        expect(service.preview.limits).to include('agents' => { 'from' => 0, 'to' => 2 })
        service.call

        expect(account.reload.limits['agents']).to eq(2)
      end

      it 'is written with the number the base gets later, by the next «Применить тариф»' do
        service.call
        allow(plans).to receive(:limits_for).and_wrap_original { |original, *args| original.call(*args).merge('agents' => 12) }

        expect(service.preview.limits).to include('agents' => { 'from' => nil, 'to' => 12 })
        expect(service.preview.kept_limits).not_to include('agents')
        service.call

        expect(account.reload.limits['agents']).to eq(12)
      end
    end

    context 'when a limit was changed by hand after the trial ended' do
      it 'gives back only the zero that is still there' do
        account.update!(limits: { 'agents' => 5, 'inboxes' => 3 })
        end_trial!
        account.update!(limits: account.limits.merge('agents' => 8))

        preview = service.preview

        expect(preview.limits).to include('inboxes' => { 'from' => 0, 'to' => 3 })
        expect(preview.limits).not_to include('agents')
        service.call
        expect(account.reload.limits).to include('agents' => 8, 'inboxes' => 3)
      end
    end

    context 'when the end of the trial kept the limits (the trial of a clinic with a plan)' do
      it 'restores nothing, even for a zero the clinic was given on purpose' do
        account.update!(limits: { 'agents' => 7 })
        service.call
        account.activate_trial!(3, keep_limits: true)
        account.expire_trial!
        account.update!(limits: account.limits.merge('inboxes' => 0))

        preview = service.preview

        expect(preview.notes).to eq([])
        expect(preview.limits).not_to include('inboxes')
        service.call
        expect(account.reload.limits).to include('agents' => 7, 'inboxes' => 0)
      end
    end

    context 'when the snapshot comes from before the plans (it has no mark of what the end did)' do
      it 'treats the end as locking the limits, as it always did' do
        account.update!(limits: { 'agents' => 5 })
        end_trial!
        attributes = account.reload.custom_attributes.deep_dup
        attributes['trial_snapshot'].delete('limits_locked')
        account.update!(custom_attributes: attributes)

        expect(service.preview.limits).to include('agents' => { 'from' => 0, 'to' => 5 })
      end
    end

    context 'when the trial was typed in by hand (no snapshot)' do
      it 'restores nothing: the trial locked nothing' do
        account.update!(custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 2.days.ago.iso8601 }, limits: { 'agents' => 0 })

        preview = service.preview

        expect(preview.notes).to eq([])
        expect(preview.limits).not_to include('agents')
      end
    end

    context 'when the trial was extended again after it ended' do
      it 'gets the limits back from the extension, and the plan finds nothing more to restore' do
        account.update!(limits: { 'agents' => 5 })
        end_trial!
        account.extend_trial!(3)

        expect(account.reload.limits).to include('agents' => 5)
        expect(service.preview.limits).not_to include('agents')
        expect(service.preview.notes).to eq(%w[trial_active trial_locks_limits])
      end
    end

    context 'when many accounts are given a plan at once' do
      it 'restores the limits of each account whose trial has ended' do
        account.update!(limits: { 'agents' => 5, 'inboxes' => 3 })
        end_trial!
        bulk = SuperAdmin::BulkAccounts.new(action: 'apply_plan', ids: [account.id], options: { chosen: '1', modules: [] }, actor: actor)

        bulk.apply

        expect(account.reload.limits).to include('agents' => 5, 'inboxes' => 3)
      end
    end
  end

  # The limits a super admin chose for the account (a number of its own, «без ограничений») are listed in
  # custom_attributes['limit_overrides'] (Accounts::LimitSettings): the plan writes its numbers into the limits that follow it only, and
  # keeps the numbers it wrote (custom_attributes['limit_plan_numbers']) to tell them from a number somebody typed.
  describe 'limits chosen for the account' do
    let(:max) { ChatwootApp.max_limit }
    let(:marks_key) { Accounts::LimitSettings::KEY }
    let(:plan_numbers_key) { Accounts::LimitSettings::PLAN_NUMBERS_KEY }

    def choose!(marks, limits)
      account.update!(limits: limits, custom_attributes: account.custom_attributes.to_h.merge(marks_key => marks))
    end

    # The plan gets numbers of its own (the base of the file has `unlimited` for two limits and nothing else)
    def plan_numbers(numbers)
      allow(plans).to(receive(:limits_for).and_wrap_original { |original, *args| original.call(*args).merge(numbers) })
    end

    it 'leaves a number chosen by hand where the plan has another one, and writes the plan into the limits that follow it' do
      choose!({ 'conversations' => 50 }, { 'conversations' => 50 })

      service.call

      expect(account.reload.limits).to eq('conversations' => 50, 'non_web_inboxes' => max)
      expect(account.custom_attributes[marks_key]).to eq('conversations' => 50)
    end

    it 'leaves «без ограничений» where the plan has a number' do
      plan_numbers('conversations' => 1000, 'agents' => 10)
      choose!({ 'conversations' => 'unlimited' }, { 'conversations' => max })

      service.call

      expect(account.reload.limits).to include('conversations' => max, 'agents' => 10)
    end

    it 'leaves a chosen number even when it is the very number the plan writes' do
      choose!({ 'non_web_inboxes' => max }, { 'non_web_inboxes' => max })

      service.call
      plan_numbers('non_web_inboxes' => 7)
      service.call

      expect(account.reload.limits).to include('non_web_inboxes' => max)
    end

    it 'makes the limits that follow the plan follow it again when its numbers change, and keeps the chosen ones' do
      choose!({ 'agents' => 3 }, { 'agents' => 3 })
      service.call
      expect(account.reload.limits).to include('conversations' => max)

      plan_numbers('conversations' => 1000, 'agents' => 10, 'inboxes' => 20)
      preview = service.preview

      expect(preview.limits).to eq(
        'conversations' => { 'from' => max, 'to' => 1000 }, 'inboxes' => { 'from' => nil, 'to' => 20 }
      )
      expect(preview.kept_limits).to eq(['agents'])
      service.call
      expect(account.reload.limits).to include('agents' => 3, 'conversations' => 1000, 'inboxes' => 20)
    end

    it 'does not list a limit as left alone when the plan would not change it' do
      choose!({ 'non_web_inboxes' => max }, { 'non_web_inboxes' => max })

      expect(service.preview.kept_limits).to be_empty
    end

    it 'reads an account from before the list: a number that equals the plan one follows the plan, any other is its own' do
      account.update!(limits: { 'conversations' => max, 'non_web_inboxes' => 3, 'agents' => 7 })

      preview = service.preview
      service.call

      expect(preview.limits).to be_empty
      expect(preview.kept_limits).to eq(['non_web_inboxes'])
      expect(account.reload.limits).to eq('conversations' => max, 'non_web_inboxes' => 3, 'agents' => 7)
      # nothing is listed for it: a number that is not the plan one is read as its own
      expect(account.custom_attributes).not_to have_key(marks_key)
      expect(Accounts::LimitSettings.new(account).source('non_web_inboxes')).to eq(:custom)
    end

    # The plans of the first two versions wrote 100 000 for the conversations and the main channels, and kept no list of what they wrote
    context 'when the plan was applied before the numbers of the plan were kept' do
      before do
        account.update!(limits: { 'conversations' => max, 'non_web_inboxes' => max, 'agents' => 7 },
                        custom_attributes: { 'plan' => 'base', 'plan_modules' => [], 'plan_version' => 2 })
      end

      it 'writes the new number of the plan into a limit that follows it, before the plan was applied again', :aggregate_failures do
        plan_numbers('conversations' => 2000)

        preview = service.preview
        service.call

        expect(preview.limits).to eq('conversations' => { 'from' => max, 'to' => 2000 })
        expect(preview.kept_limits).to be_empty
        expect(account.reload.limits).to eq('conversations' => 2000, 'non_web_inboxes' => max, 'agents' => 7)
        expect(account.custom_attributes[plan_numbers_key]).to eq('conversations' => 2000, 'non_web_inboxes' => max)
        expect(Accounts::LimitSettings.new(account).source('conversations')).to eq(:plan)
      end

      it 'leaves a number somebody typed, and says so', :aggregate_failures do
        plan_numbers('conversations' => 2000)
        account.update!(limits: account.limits.merge('conversations' => 300))

        preview = service.preview
        service.call

        expect(preview.limits).to be_empty
        expect(preview.kept_limits).to eq(['conversations'])
        expect(account.reload.limits['conversations']).to eq(300)
      end

      it 'is the same for many accounts at once' do
        plan_numbers('conversations' => 2000)
        bulk = SuperAdmin::BulkAccounts.new(action: 'apply_plan', ids: [account.id], options: { chosen: '1', modules: [] }, actor: actor)

        bulk.apply

        expect(account.reload.limits).to include('conversations' => 2000, 'non_web_inboxes' => max, 'agents' => 7)
      end
    end

    it 'keeps the numbers it wrote, so that a number of the plan that changes later is told from a number typed by hand' do
      service.call

      expect(account.reload.custom_attributes[plan_numbers_key]).to eq('conversations' => max, 'non_web_inboxes' => max)

      plan_numbers('agents' => 10)
      service.call

      expect(account.reload.custom_attributes[plan_numbers_key]).to eq('conversations' => max, 'non_web_inboxes' => max, 'agents' => 10)
    end

    it 'does not keep a number for a limit chosen by hand, nor for one the plan leaves alone' do
      choose!({ 'conversations' => 50 }, { 'conversations' => 50, 'inboxes' => 9 })

      service.call

      expect(account.reload.custom_attributes[plan_numbers_key]).to eq('non_web_inboxes' => max)
    end

    it 'keeps a number typed by hand where the plan had none through the first plan and a number that comes to the plan later' do
      account.update!(limits: { 'agents' => 10, 'conversations' => max, 'non_web_inboxes' => max },
                      custom_attributes: { 'plan' => 'base', 'plan_modules' => [], 'plan_version' => 2 })

      service.call
      expect(Accounts::LimitSettings.new(account.reload).source('agents')).to eq(:custom)

      plan_numbers('agents' => 5)
      preview = service.preview
      service.call

      expect(preview.limits).to be_empty
      expect(preview.kept_limits).to eq(['agents'])
      expect(account.reload.limits['agents']).to eq(10)
      expect(Accounts::LimitSettings.new(account).source('agents')).to eq(:custom)
    end

    it 'writes the new number of the plan over the number it wrote, and not over a number written by anybody else' do
      service.call
      account.update!(limits: account.limits.merge('inboxes' => 6, 'emails' => 40))
      plan_numbers('conversations' => 1000, 'inboxes' => 20)
      service.call # 'inboxes' is somebody's number (the plan had none when it was applied before): it stays
      expect(account.reload.limits).to include('conversations' => 1000, 'inboxes' => 6, 'emails' => 40)

      plan_numbers('conversations' => 2000, 'inboxes' => 20)
      service.call

      expect(account.reload.limits).to include('conversations' => 2000, 'inboxes' => 6)
    end

    it 'does not write the list of the limits chosen by hand when nothing was chosen' do
      service.call

      expect(account.reload.custom_attributes).not_to have_key(marks_key)
    end

    it 'keeps the list a plan wrote when the plan is applied again' do
      choose!({ 'inboxes' => 4 }, { 'inboxes' => 4 })

      2.times { service(%w[ai_agents]).call }

      expect(account.reload.limits).to include('inboxes' => 4)
      expect(account.custom_attributes[marks_key]).to eq('inboxes' => 4)
    end

    it 'does not write the list or the limits in a preview' do
      choose!({ 'inboxes' => 4 }, { 'inboxes' => 4 })
      stored = Account.find(account.id).attributes

      service(%w[ai_agents]).preview

      expect(Account.find(account.id).attributes).to eq(stored)
    end

    it 'puts the limits chosen into the answer of the preview' do
      plan_numbers('conversations' => 1000)
      choose!({ 'conversations' => 50 }, { 'conversations' => 50 })

      expect(service.preview.as_json).to include('kept_limits' => ['conversations'])
    end

    it 'is the same for many accounts at once' do
      choose!({ 'conversations' => 50 }, { 'conversations' => 50 })
      bulk = SuperAdmin::BulkAccounts.new(action: 'apply_plan', ids: [account.id], options: { chosen: '1', modules: [] }, actor: actor)

      bulk.apply

      expect(account.reload.limits).to include('conversations' => 50, 'non_web_inboxes' => max)
    end

    it 'does not let the end of a trial lock a limit chosen by hand, nor the restore touch it' do
      service.call
      choose!({ 'agents' => 2 }, account.reload.limits.merge('agents' => 2, 'inboxes' => 3))
      account.reload.activate_trial!(3)
      account.expire_trial!

      expect(account.reload.limits).to include('agents' => 2, 'inboxes' => 0)
      expect(service.preview.limits).to include('inboxes' => { 'from' => 0, 'to' => 3 })
      expect(service.preview.limits).not_to include('agents')
      service.call
      expect(account.reload.limits).to include('agents' => 2, 'inboxes' => 3)
    end
  end

  describe 'modules' do
    it 'rejects an unknown module before anything happens' do
      expect { service(%w[ai_agents ghost]) }.to raise_error(described_class::UnknownModule, /ghost/)
    end

    it 'treats a missing list as the base alone and ignores duplicates and blanks' do
      expect(service(nil).modules).to eq([])
      expect(service(['quality', '', 'quality']).modules).to eq(%w[quality])
    end
  end
end
