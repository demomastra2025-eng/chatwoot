# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Account, type: :model do
  describe 'Trial functionality' do
    let(:account) { create(:account) }

    describe '#activate_trial!' do
      it 'activates trial for 3 days and enables key trial features' do
        expect(account.trial?).to be(false)
        account.activate_trial!(3)
        expect(account.trial?).to be(true)
        expect(account.trial_active?).to be(true)
        expect(account.trial_expired?).to be(false)
        expect(account.trial_expires_at).to be > 2.days.from_now
        expect(account.feature_channel_voice?).to be(true)
        expect(account.feature_captain_integration?).to be(true)
        expect(account.feature_crm?).to be(true)
      end
    end

    describe '#extend_trial!' do
      it 'extends trial by specified days' do
        account.activate_trial!(3)
        initial_expiry = account.trial_expires_at
        account.extend_trial!(3)
        expect(account.trial_expires_at).to be > initial_expiry
      end
    end

    describe '#expire_trial!' do
      it 'marks trial as expired and zeros limits' do
        account.activate_trial!(3)
        account.expire_trial!
        expect(account.trial_expired?).to be(true)
        expect(account.trial_active?).to be(false)
        expect(account.limits['agents']).to eq(0)
        expect(account.limits['inboxes']).to eq(0)
      end
    end
  end
end
