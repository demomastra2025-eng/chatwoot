require 'rails_helper'

RSpec.describe SuperAdmin::AccountPlanState do
  let(:account) { create(:account) }
  let(:state) { described_class.new(account.reload) }

  def chip_texts
    state.chips.map(&:text)
  end

  context 'when the clinic has no plan' do
    it 'is not assigned and says so' do
      expect(state).not_to be_assigned
      expect(state.label).to eq('Не назначен')
      expect(state.modules).to eq([])
    end

    it 'shows one quiet chip «Не назначен»' do
      expect(state.chips.map { |chip| [chip.text, chip.tone] }).to eq([['Не назначен', :quiet]])
    end

    it 'has no drift to report' do
      expect(state.drift).to be_nil
      expect(state).not_to be_drifted
    end
  end

  context 'when the clinic has the base and modules' do
    before { Accounts::ApplyPlan.new(account: account, modules: %w[broadcasts ai_agents]).call }

    it 'lists the base first and the modules in the order of the registry' do
      expect(state).to be_assigned
      expect(chip_texts).to eq(%w[База ИИ-агенты Рассылки])
      expect(state.chips.map(&:tone)).to eq(%i[iris slate slate])
      expect(state.label).to eq('База + ИИ-агенты + Рассылки')
    end

    it 'ignores a module that is no longer in the registry' do
      account.update!(custom_attributes: account.custom_attributes.merge('plan_modules' => %w[ghost quality]))

      expect(state.modules).to eq(%w[quality])
      expect(chip_texts).to eq(['База', 'Контроль качества'])
    end

    it 'knows when the plan was applied and its version' do
      expect(state.version).to eq(Accounts::Plans.version)
      expect(state.applied_at).to be_within(1.minute).of(Time.current)
    end

    it 'has no drift right after the plan was applied' do
      expect(state.drift).to eq(extra: [], missing: [])
      expect(state).not_to be_drifted
    end

    it 'sees a function switched on beyond the plan and one switched off' do
      account.enable_features!('sla')
      account.disable_features!('crm')

      expect(state.drift[:extra]).to include('sla')
      expect(state.drift[:missing]).to include('crm')
      expect(state).to be_drifted
    end
  end

  describe '#status' do
    it 'is active for a clinic in good standing, with its Russian name' do
      expect(state.status).to eq(:active)
      expect(state.status_label).to eq('Активен')
    end

    it 'is suspended for a blocked clinic' do
      account.update!(status: :suspended)

      expect(state.status).to eq(:suspended)
      expect(state.status_label).to eq('Заблокирован')
    end

    it 'puts «на удаление» before «заблокирована»' do
      account.update!(status: :suspended, custom_attributes: { 'marked_for_deletion_at' => 3.days.from_now.iso8601 })

      expect(state.status).to eq(:deleting)
      expect(state.status_label).to eq('На удаление')
    end
  end

  describe '#trial_locks_limits?' do
    it 'is true for the trial the card could start on a clinic without a plan' do
      expect(state.trial_locks_limits?).to be(true)
    end

    it 'is false for the trial the card could start on a clinic with a plan' do
      Accounts::ApplyPlan.new(account: account, modules: []).call

      expect(state.trial_locks_limits?).to be(false)
    end

    it 'follows the trial itself once there is one: a trial nobody chose locks, even with a plan' do
      Accounts::ApplyPlan.new(account: account, modules: []).call
      account.activate_trial!(3)

      expect(state.trial_locks_limits?).to be(true)
    end

    it 'follows the trial itself: a trial a super admin started on a clinic with a plan keeps the limits' do
      Accounts::ApplyPlan.new(account: account, modules: []).call
      account.activate_trial!(3, keep_limits: true)

      expect(state.trial_locks_limits?).to be(false)
    end
  end

  describe 'the trial' do
    it 'is none for a clinic that never had one' do
      expect(state.trial_state).to eq(:none)
      expect(state.trial_remaining).to be_nil
      expect(state.trial_remaining_short).to be_nil
      expect(state).to be_can_start_trial
      expect(state).not_to be_trial_managed
    end

    it 'counts a trial that has just started for 3 days as 3 дн.' do
      account.activate_trial!(3)

      expect(state.trial_state).to eq(:active)
      expect(state).to be_trial_managed
      expect(state).not_to be_can_start_trial
      expect(state.trial_remaining_short).to eq('3 дн.')
      expect(state.chips.last.text).to eq('Пробный · осталось 3 дн.')
      expect(state.chips.last.tone).to eq(:blue)
    end

    it 'counts down to hours and minutes and turns amber on the last day' do
      account.activate_trial!(3)
      travel_to((2.days + 18.hours + 5.minutes).from_now) do
        expect(state.trial_remaining_short).to eq('6 ч.')
        expect(state.chips.last.tone).to eq(:amber)
        expect(state.trial_remaining).to include(days: 0, hours: 5)
      end
      travel_to((2.days + 23.hours + 20.minutes + 30.seconds).from_now) do
        expect(state.trial_remaining_short).to eq('40 мин.')
      end
    end

    it 'shows an ended trial as «Пробный истёк»' do
      account.activate_trial!(3)
      account.expire_trial!

      expect(state.trial_state).to eq(:expired)
      expect(state.trial_remaining).to be_nil
      expect(state.chips.last.text).to eq('Пробный истёк')
      expect(state.chips.last.tone).to eq(:ruby)
      expect(state.trial_expired_at).to be_within(1.minute).of(Time.current)
    end

    it 'keeps the trial chip next to the plan chips' do
      Accounts::ApplyPlan.new(account: account, modules: []).call
      account.activate_trial!(3)

      expect(chip_texts).to eq(['База', 'Пробный · осталось 3 дн.'])
    end

    it 'is not managed without a snapshot (a trial typed in by hand), but can be started properly' do
      account.update!(custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 2.days.from_now.iso8601 })

      expect(state.trial_state).to eq(:active)
      expect(state).not_to be_trial_managed
      expect(state).to be_can_start_trial
    end

    it 'cannot start a trial on a clinic with another manually assigned plan type' do
      account.update!(custom_attributes: { 'plan_type' => 'growth' })

      expect(state).not_to be_can_start_trial
    end
  end
end
