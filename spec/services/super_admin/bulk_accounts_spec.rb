# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::BulkAccounts do
  let(:actor) { create(:super_admin) }
  let(:audit_state) { { floor: 0 } }

  def bulk(action, accounts, **options)
    ids = accounts.map { |account| account.respond_to?(:id) ? account.id : account }
    described_class.new(action: action, ids: ids, options: options, actor: actor)
  end

  def bare_account
    create(:account).tap { |record| record.disable_features!(*Featurable::FEATURE_NAMES) }
  end

  # Runs the action; the entries of the audit log that `audits` shows are the ones it wrote (not the ones of the setup)
  def run(bulk_run)
    audit_state[:floor] = Audited::Audit.maximum(:id).to_i
    bulk_run.apply
  end

  def audits(account, action = nil)
    scope = Audited::Audit.where(auditable_type: 'Account', auditable_id: account.id).where('id > ?', audit_state[:floor])
    action ? scope.where(action: action) : scope
  end

  describe '.parse_ids' do
    it 'turns a list of numbers into numbers without repeats and drops garbage' do
      expect(described_class.parse_ids(%w[3 1 3 x 2.5 -4 0 12abc])).to eq([3, 1])
    end

    it 'takes nothing as an empty list and refuses what is not a list' do
      expect(described_class.parse_ids(nil)).to eq([])
      expect(described_class.parse_ids('1,2')).to be_nil
      expect(described_class.parse_ids({ '0' => '1' })).to be_nil
    end
  end

  describe 'the request' do
    it 'knows its action' do
      expect(bulk('suspend', [1])).to be_action_known
      expect(bulk('delete_everything', [1])).not_to be_action_known
      expect(described_class::ACTIONS).to eq(%w[apply_plan extend_trial suspend activate link_organization])
    end

    it 'allows up to 200 accounts and refuses more' do
      expect(bulk('suspend', (1..200).to_a)).not_to be_too_many
      expect(bulk('suspend', (1..201).to_a)).to be_too_many
      expect(bulk('suspend', [])).to be_empty
    end
  end

  describe 'blocking and unblocking' do
    let(:active) { create(:account, status: 'active') }
    let(:suspended) { create(:account, status: 'suspended') }

    it 'previews which accounts would change and which are skipped, with the reason' do
      preview = bulk('suspend', [active, suspended]).preview

      expect(preview.entries.map(&:outcome)).to eq(%i[change skip])
      expect(preview.entries.last.reason).to eq(:already_suspended)
      expect(preview).to have_attributes(changing: 1, skipping: 1, reasons: { already_suspended: 1 })
      expect(active.reload).to be_active
    end

    it 'blocks the accounts, skips the ones already blocked and leaves one entry of the audit log for each account it changed' do
      result = run(bulk('suspend', [active, suspended]))

      expect(result).to have_attributes(done: 1, skipped: { already_suspended: 1 })
      expect(active.reload).to be_suspended
      expect(audits(active).pluck(:action)).to eq(['suspend_account'])
      expect(audits(active).first).to have_attributes(
        user_id: actor.id, comment: 'super_admin', audited_changes: { 'status' => %w[active suspended], 'bulk' => true }
      )
      expect(audits(suspended)).to be_empty
    end

    it 'unblocks the accounts' do
      result = run(bulk('activate', [suspended, active]))

      expect(result).to have_attributes(done: 1, skipped: { already_active: 1 })
      expect(suspended.reload).to be_active
      expect(audits(suspended).pluck(:action)).to eq(['activate_account'])
    end

    it 'warns about blocking and about nothing else' do
      expect(bulk('suspend', [active])).to be_warning
      expect(bulk('activate', [active])).not_to be_warning
    end
  end

  describe 'accounts that cannot be touched' do
    it 'skips an account marked for deletion and a number that is not an account any more' do
      doomed = create(:account, status: 'active')
      SuperAdmin::AccountDeletion.new(account: doomed, actor: actor).schedule

      result = run(bulk('suspend', [doomed, 987_654_321]))

      expect(result).to have_attributes(done: 0, skipped: { deleting: 1, missing: 1 })
      expect(doomed.reload).to be_active
      expect(audits(doomed)).to be_empty
    end

    it 'goes on after an account that fails, and says it failed' do
      broken = create(:account, status: 'active')
      broken.update_columns(name: '') # rubocop:disable Rails/SkipsModelValidations -- it cannot be saved any more
      fine = create(:account, status: 'active')

      result = run(bulk('suspend', [broken, fine]))

      expect(result).to have_attributes(done: 1, skipped: { failed: 1 })
      expect(broken.reload).to be_active
      expect(fine.reload).to be_suspended
      expect(audits(broken)).to be_empty
    end

    it 'stops starting accounts when its time is up, leaves the rest untouched and says so' do
      done, late, later = Array.new(3) { create(:account, status: 'active') }
      run_of_the_request = bulk('suspend', [done, late, later])
      allow(run_of_the_request).to receive(:out_of_time?).and_return(false, true, true)

      result = run(run_of_the_request)

      expect(result).to have_attributes(done: 1, skipped: { out_of_time: 2 })
      expect(done.reload).to be_suspended
      expect([late.reload, later.reload]).to all(be_active)
      expect(audits(done, 'suspend_account').count).to eq(1)
      expect(audits(late)).to be_empty
    end

    it 'does not take a request timeout for an account that failed' do
      first, second = Array.new(2) { create(:account, status: 'active') }
      run_of_the_request = bulk('suspend', [first, second])
      allow(run_of_the_request.strategy).to receive(:perform).and_raise(Rack::Timeout::RequestTimeoutException.new({}))

      expect { run(run_of_the_request) }.to raise_error(Rack::Timeout::RequestTimeoutException)
      expect(second.reload).to be_active
    end

    it 'looks at an account again when it is its turn' do
      account = create(:account, status: 'active')
      run_of_the_request = bulk('suspend', [account])
      run_of_the_request.preview
      account.update!(status: 'suspended') # somebody else blocked it after the confirmation page was drawn

      result = run(run_of_the_request)

      expect(result).to have_attributes(done: 0, skipped: { already_suspended: 1 })
      expect(audits(account, 'suspend_account')).to be_empty
    end
  end

  describe 'the trial' do
    let(:on_trial) { create(:account).tap { |account| account.activate_trial!(7, keep_limits: true) } }
    let(:without_trial) { create(:account) }

    it 'previews the new end of the trial' do
      entry = bulk('extend_trial', [on_trial, without_trial]).preview.entries

      expect(entry.first).to be_change
      expect(entry.first.detail[:from]).to be_within(1.second).of(on_trial.trial_expires_at)
      expect(entry.first.detail[:to]).to be_within(1.second).of(on_trial.trial_expires_at + Accounts::Plans.trial_days.days)
      expect(entry.last).to have_attributes(outcome: :skip, reason: :not_trial)
    end

    it 'extends the trial by the usual number of days and leaves one entry of the audit log' do
      expires_before = on_trial.trial_expires_at

      result = run(bulk('extend_trial', [on_trial, without_trial]))

      expect(result).to have_attributes(done: 1, skipped: { not_trial: 1 })
      expect(on_trial.reload.trial_expires_at).to be_within(1.second).of(expires_before + Accounts::Plans.trial_days.days)
      expect(audits(on_trial).pluck(:action)).to eq(['extend_trial'])
      expect(audits(on_trial).first.audited_changes).to include('bulk' => true, 'trial_expires_at' => on_trial.custom_attributes['trial_expires_at'])
      expect(audits(on_trial).first).to have_attributes(user_id: actor.id, comment: 'super_admin')
    end

    it 'opens a trial that has ended again' do
      on_trial.expire_trial!
      expect(on_trial.reload).to be_trial_expired

      entry = bulk('extend_trial', [on_trial]).preview.entries.first
      run(bulk('extend_trial', [on_trial]))

      expect(entry.detail[:ended]).to be(true)
      expect(on_trial.reload).to be_trial_active
    end
  end

  describe 'the plan' do
    let(:first) { bare_account }
    let(:second) { bare_account }

    it 'is not ready until the modules are chosen, and not valid with a module that does not exist' do
      expect(bulk('apply_plan', [first])).to be_parameter
      expect(bulk('apply_plan', [first])).not_to be_ready
      expect(bulk('apply_plan', [first], chosen: '1', modules: %w[ai_agents])).to be_ready
      expect(bulk('apply_plan', [first], chosen: '1')).to be_ready # the base alone
      invalid = bulk('apply_plan', [first], chosen: '1', modules: %w[ghost])
      expect(invalid).not_to be_ready
      expect(invalid.error).to eq(:unknown_module)
      expect(bulk('apply_plan', [first], chosen: '1', modules: { ai_agents: '1' }).error).to eq(:unknown_module)
    end

    it 'previews what the plan would switch in each account, without writing anything' do
      entry = bulk('apply_plan', [first], chosen: '1', modules: %w[ai_agents]).preview.entries.first

      expect(entry).to be_change
      expect(entry.detail[:diff].enable).to include('captain_integration')
      expect(first.reload.custom_attributes).not_to have_key('plan')
      expect(audits(first)).to be_empty
    end

    it 'applies base and the modules and leaves ONE entry of the audit log for each account, marked as bulk' do
      result = run(bulk('apply_plan', [first, second], chosen: '1', modules: %w[ai_agents broadcasts]))

      expect(result).to have_attributes(done: 2, skipped: {})
      [first, second].each do |account|
        account.reload
        expect(account.custom_attributes).to include('plan' => 'base', 'plan_modules' => %w[ai_agents broadcasts])
        expect(account.feature_enabled?('captain_integration')).to be(true)
        expect(audits(account).pluck(:action)).to eq(['apply_plan'])
        expect(audits(account).first).to have_attributes(user_id: actor.id, comment: 'super_admin')
        expect(audits(account).first.audited_changes).to include('bulk' => true, 'after' => include('plan_modules' => %w[ai_agents broadcasts]))
      end
    end

    it 'skips an account that is already exactly on this plan' do
      Accounts::ApplyPlan.new(account: first, modules: %w[ai_agents], actor: actor).call

      result = run(bulk('apply_plan', [first, second], chosen: '1', modules: %w[ai_agents]))

      expect(result).to have_attributes(done: 1, skipped: { no_changes: 1 })
      expect(audits(first)).to be_empty
      expect(audits(second).pluck(:action)).to eq(['apply_plan'])
    end

    it 'assigns the plan again to an account that lost the mark of its plan, though its functions are right' do
      Accounts::ApplyPlan.new(account: first, modules: [], actor: actor).call
      first.update!(custom_attributes: first.custom_attributes.except('plan', 'plan_modules'))

      entry = bulk('apply_plan', [first], chosen: '1').preview.entries.first

      expect(entry).to be_change
      expect(entry.detail[:diff]).not_to be_changed
    end
  end

  describe 'organizations' do
    let(:organization) { create(:organization, :with_requisites, name: 'Алатау Медикал') }
    let(:other) { create(:organization, :with_requisites, name: 'Сезим') }
    let(:free) { create(:account) }
    let(:held) { create(:account, organization: other) }
    let(:there) { create(:account, organization: organization) }

    it 'is not ready until an organization or «Без организации» is chosen, and refuses one that does not exist' do
      expect(bulk('link_organization', [free])).not_to be_ready
      expect(bulk('link_organization', [free], chosen: '1')).not_to be_ready # a form that forgot the field never unlinks anybody
      expect(bulk('link_organization', [free], chosen: '1', organization_id: '')).not_to be_ready
      expect(bulk('link_organization', [free], chosen: '1', organization_id: '999999').error).to eq(:unknown_organization)
      expect(bulk('link_organization', [free], chosen: '1', organization_id: organization.id.to_s)).to be_ready
      expect(bulk('link_organization', [free], chosen: '1', organization_id: 'none')).to be_ready
    end

    it 'previews where each account comes from and where it goes' do
      entries = bulk('link_organization', [free, held, there], chosen: '1', organization_id: organization.id.to_s).preview.entries

      expect(entries.map(&:outcome)).to eq(%i[change change skip])
      expect(entries[1].detail).to eq(from: other, to: organization)
      expect(entries.last.reason).to eq(:already_there)
    end

    it 'links the free accounts, moves the ones of another organization, and marks the entries as bulk' do
      result = run(bulk('link_organization', [free, held, there], chosen: '1', organization_id: organization.id.to_s))

      expect(result).to have_attributes(done: 2, skipped: { already_there: 1 })
      expect([free, held, there].map { |account| account.reload.organization_id }).to eq([organization.id] * 3)
      expect(audits(free).pluck(:action)).to eq(['link_organization'])
      expect(audits(held).pluck(:action)).to eq(['link_organization'])
      expect(audits(held).first.audited_changes).to include('bulk' => true, 'organization_id' => [other.id, organization.id])
      expect(audits(held).first).to have_attributes(user_id: actor.id, comment: 'super_admin')
    end

    it 'leaves the entries of the organizations on both sides of a move' do
      run(bulk('link_organization', [free, held], chosen: '1', organization_id: organization.id.to_s))

      expect(Audited::Audit.where(auditable: other, action: 'unlink_account').count).to eq(1)
      expect(Audited::Audit.where(auditable: organization, action: 'link_account').count).to eq(2)
    end

    it 'unlinks the accounts with «Без организации» and skips the ones that have none' do
      result = run(bulk('link_organization', [free, held], chosen: '1', organization_id: 'none'))

      expect(result).to have_attributes(done: 1, skipped: { already_free: 1 })
      expect(held.reload.organization_id).to be_nil
      expect(audits(held).first.audited_changes).to include('bulk' => true, 'organization_id' => [other.id, nil])
    end
  end

  describe 'the cost of the preview' do
    it 'does not grow with the number of accounts' do
      few_accounts = create_list(:account, 2)
      many_accounts = few_accounts + create_list(:account, 10)
      bulk('suspend', few_accounts).preview # the first run reads the schema
      few = sql_queries_during { bulk('suspend', few_accounts).preview }.size
      many = sql_queries_during { bulk('suspend', many_accounts).preview }.size

      expect(many).to eq(few)
    end
  end
end
