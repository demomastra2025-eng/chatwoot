require 'rails_helper'

# The operator and channel limits that the end of a trial put at 0 and that still sit there, with the values from before the trial
RSpec.describe Account, '#trial_held_limits' do
  let(:account) { create(:account) }

  def end_trial!(keep_limits: false)
    account.activate_trial!(3, keep_limits: keep_limits)
    account.expire_trial!
  end

  it 'is empty for an account that never had a trial' do
    account.update!(limits: { 'agents' => 0, 'inboxes' => 0 })

    expect(account.trial_held_limits).to eq({})
  end

  it 'is empty while the trial runs: nothing is locked yet' do
    account.update!(limits: { 'agents' => 5 })
    account.activate_trial!(3)

    expect(account.trial_held_limits).to eq({})
  end

  it 'gives the value each limit had before the trial, once the trial has ended and put it at zero' do
    account.update!(limits: { 'agents' => 5, 'inboxes' => 3 })
    end_trial!

    expect(account.reload.limits).to include('agents' => 0, 'inboxes' => 0)
    expect(account.trial_held_limits).to eq('agents' => 5, 'inboxes' => 3)
  end

  it 'gives nil for a limit that was not set before the trial' do
    account.update!(limits: { 'agents' => 5 })
    end_trial!

    expect(account.trial_held_limits).to eq('agents' => 5, 'inboxes' => nil)
  end

  it 'leaves out a limit that is not at zero any more: that is somebody\'s decision' do
    account.update!(limits: { 'agents' => 5, 'inboxes' => 3 })
    end_trial!
    account.update!(limits: account.limits.merge('inboxes' => 9))

    expect(account.trial_held_limits).to eq('agents' => 5)
  end

  it 'leaves out a limit that was zero before the trial as well: there is nothing to give back' do
    account.update!(limits: { 'agents' => 0, 'inboxes' => 3 })
    end_trial!

    expect(account.trial_held_limits).to eq('inboxes' => 3)
  end

  it 'is empty when the end of the trial kept the limits' do
    account.update!(limits: { 'agents' => 5 })
    Accounts::ApplyPlan.new(account: account, modules: []).call
    end_trial!(keep_limits: true)

    expect(account.trial_held_limits).to eq({})
  end

  it 'is empty for a trial typed in by hand, which has no snapshot' do
    account.update!(custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 1.day.ago.iso8601 }, limits: { 'agents' => 0 })

    expect(account.trial_held_limits).to eq({})
  end

  it 'is empty again once the trial is extended and the limits come back' do
    account.update!(limits: { 'agents' => 5 })
    end_trial!
    account.extend_trial!(3)

    expect(account.reload.trial_held_limits).to eq({})
  end
end
