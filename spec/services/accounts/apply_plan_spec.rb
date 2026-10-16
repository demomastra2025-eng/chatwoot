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

      expect(preview).to have_attributes(plan: 'base', modules: %w[ai_agents], plan_version: 1, previous_plan: nil, previous_modules: [])
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

      expect(json).to include('plan' => 'base', 'modules' => %w[broadcasts], 'plan_version' => 1, 'changed' => true)
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
      account.update!(limits: { 'agents' => 7, 'storage_bytes' => 5_000, 'conversations' => 500, 'non_web_inboxes' => 0 })

      service.call

      expect(account.reload.limits).to eq(
        'agents' => 7, 'storage_bytes' => 5_000, 'conversations' => ChatwootApp.max_limit, 'non_web_inboxes' => ChatwootApp.max_limit
      )
    end

    it 'lets the account keep its own limits when the plan only has to fill the blanks' do
      account.update!(limits: { 'conversations' => 10 })

      service(keep_existing_limits: true).call

      expect(account.reload.limits).to eq('conversations' => 10, 'non_web_inboxes' => ChatwootApp.max_limit)
    end

    it 'stores the plan, its modules, its version and the moment it was applied in Astana time' do
      account.update!(custom_attributes: { 'industry' => 'clinic' })

      service(%w[broadcasts ai_agents]).call

      expect(account.reload.custom_attributes).to include(
        'industry' => 'clinic', 'plan' => 'base', 'plan_modules' => %w[ai_agents broadcasts], 'plan_version' => 1
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

    it 'tells that an ended trial still holds the operator and channel limits at zero' do
      account.activate_trial!(3)
      account.expire_trial!

      expect(service.preview.notes).to eq(['trial_expired'])
      service.call
      expect(account.reload.limits).to include('agents' => 0, 'inboxes' => 0)
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
        'after' => { 'plan' => 'base', 'plan_modules' => %w[ai_agents], 'plan_version' => 1 }
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
