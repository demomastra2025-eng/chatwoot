require 'rails_helper'

RSpec.describe Account, '#access_control_mode' do
  it 'defaults new accounts to legacy mode' do
    account = create(:account)

    expect(account).to be_access_control_mode_legacy
  end

  it 'rejects direct mode changes that bypass the transition service' do
    account = create(:account)

    expect(account.update(access_control_mode: :shadow)).to be(false)
    expect(account.errors[:access_control_mode]).to include('must be changed through AccessControl::ModeTransition')
    expect(account.reload).to be_access_control_mode_legacy
  end

  it 'enforces supported modes at the database boundary' do
    account = create(:account)

    expect do
      described_class.transaction(requires_new: true) do
        account.update_column(:access_control_mode, 'unknown') # rubocop:disable Rails/SkipsModelValidations
      end
    end.to raise_error(ActiveRecord::StatementInvalid)
  end
end
