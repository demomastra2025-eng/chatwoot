require 'rails_helper'

RSpec.describe Account, '#access_control_mode audit' do
  it 'records guarded mode transitions in the account audit trail' do
    account = create(:account)

    expect do
      AccessControl::ModeTransition.call(account: account, to: :shadow)
    end.to change { account.audits.count }.by(1)

    expect(account.audits.last.audited_changes.fetch('access_control_mode')).to eq(%w[legacy shadow])
  end
end
