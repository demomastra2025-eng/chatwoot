# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Account, type: :model do
  describe 'Trial functionality' do
    let(:account) { create(:account) }

    describe '#activate_trial!' do
      it 'activates a trial for 3 days' do
        expect(account.trial?).to be(false)
        account.activate_trial!(3)
        expect(account.trial?).to be(true)
        expect(account.trial_active?).to be(true)
        expect(account.trial_expired?).to be(false)
        expect(account.trial_expires_at).to be > 2.days.from_now
      end

      it 'enables the key trial features' do
        account.activate_trial!(3)
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
        expect(account.custom_attributes['trial_snapshot']).to include('limits_locked' => true)
      end
    end

    describe 'a clinic that has a plan' do
      before do
        account.update!(limits: { 'agents' => 7, 'inboxes' => 9 })
        Accounts::ApplyPlan.new(account: account, modules: %w[quality]).call
        account.activate_trial!(3)
      end

      it 'loses the functions of the trial when it ends, but keeps the plan and its limits' do
        expect(account.expire_trial!).to be(true)
        account.reload

        expect(account.feature_enabled?('captain_integration')).to be(false)
        expect(account.feature_enabled?('sla')).to be(true)
        expect(account.feature_enabled?('crm')).to be(true)
        expect(account.limits).to include('agents' => 7, 'inboxes' => 9)
        expect(account.custom_attributes).to include('plan' => 'base', 'plan_modules' => %w[quality])
        expect(account.custom_attributes['trial_snapshot']).to include('limits_locked' => false)
      end

      it 'is not locked out of operators and channels by the scheduled expiry either' do
        account.update!(custom_attributes: account.custom_attributes.merge('trial_expires_at' => 1.hour.ago.iso8601))

        Accounts::ExpireTrialsJob.perform_now

        expect(account.reload.custom_attributes['trial_expired_at']).to be_present
        expect(account.limits).to include('agents' => 7, 'inboxes' => 9)
      end

      it 'keeps the limits set after the end when the trial is extended' do
        account.expire_trial!
        account.update!(limits: account.limits.merge('agents' => 12))

        account.extend_trial!(3)
        account.reload

        expect(account.trial_active?).to be(true)
        expect(account.feature_enabled?('captain_integration')).to be(true)
        expect(account.limits).to include('agents' => 12, 'inboxes' => 9)
      end
    end

    describe 'a clinic that got its plan after the trial had locked its limits' do
      it 'gets the earlier limits back when the trial is extended' do
        account.update!(limits: { 'agents' => 7 })
        account.activate_trial!(3)
        account.expire_trial!
        expect(account.limits).to include('agents' => 0, 'inboxes' => 0)

        Accounts::ApplyPlan.new(account: account, modules: []).call
        account.extend_trial!(3)

        expect(account.reload.limits).to include('agents' => 7)
        expect(account.limits).not_to have_key('inboxes')
      end
    end

    describe 'trial features from the plans' do
      let(:plans) { Accounts::Plans }

      def legacy_trial_account(features: [])
        account.enable_features!(*Account::LEGACY_TRIAL_FEATURES, 'channel_email', 'campaigns')
        account.update!(
          custom_attributes: {
            'plan_type' => 'trial', 'trial_expires_at' => 1.hour.ago.iso8601,
            'trial_snapshot' => { 'features' => features, 'limits' => { 'agents' => 7 }, 'taken_at' => 2.days.ago.iso8601 }
          },
          limits: { 'agents' => 7 }
        )
        account
      end

      it 'grants the base plus the trial modules, without the fake channel_whatsapp flag' do
        expect(Account::TRIAL_FEATURES).to eq(plans.trial_features)
        expect(Account::TRIAL_FEATURES).to include('channel_voice', 'captain_integration', 'crm', 'channel_email', 'labels')
        expect(Account::TRIAL_FEATURES).not_to include('channel_whatsapp', 'campaigns', 'sla', 'scheduling_finance')
      end

      it 'takes its length from the plans' do
        account.activate_trial!

        expect(account.trial_expires_at).to be_within(1.minute).of(plans.trial_days.days.from_now)
      end

      it 'stores the exact list it granted in the snapshot' do
        account.activate_trial!(3)

        expect(account.custom_attributes['trial_snapshot']['trial_features']).to eq(Account::TRIAL_FEATURES)
        expect(account.granted_trial_features).to eq(Account::TRIAL_FEATURES)
      end

      it 'ends with the list stored in its snapshot, whatever the plans say later' do
        account.activate_trial!(3)
        attrs = account.custom_attributes.deep_dup
        attrs['trial_snapshot']['trial_features'] = %w[crm channel_voice]
        account.update!(custom_attributes: attrs)
        account.enable_features!('channel_email')

        account.expire_trial!
        account.reload

        expect(account.feature_enabled?('crm')).to be(false)
        expect(account.feature_enabled?('channel_voice')).to be(false)
        expect(account.feature_enabled?('captain_integration')).to be(true)
        expect(account.feature_enabled?('channel_email')).to be(true)
      end

      it 'gives back exactly the stored list when an ended trial is extended' do
        account.activate_trial!(3)
        attrs = account.custom_attributes.deep_dup
        attrs['trial_snapshot']['trial_features'] = %w[crm channel_voice]
        account.update!(custom_attributes: attrs)
        account.expire_trial!
        account.disable_features!('channel_email')

        account.extend_trial!(3)
        account.reload

        expect(account.feature_enabled?('crm')).to be(true)
        expect(account.feature_enabled?('channel_voice')).to be(true)
        expect(account.feature_enabled?('channel_email')).to be(false)
      end

      it 'ends a trial that began before the list was stored with exactly the old fixed list' do
        legacy_trial_account

        expect(account.expire_trial!).to be(true)
        account.reload

        Account::LEGACY_TRIAL_FEATURES.each do |flag|
          expect(account.feature_enabled?(flag)).to be(false)
        end
        expect(account.feature_enabled?('channel_email')).to be(true)
        expect(account.feature_enabled?('campaigns')).to be(true)
        expect(account.limits).to include('agents' => 0, 'inboxes' => 0)
      end

      it 'reopens a trial that began before the list was stored with the old fixed list only' do
        legacy_trial_account
        account.expire_trial!
        account.disable_features!('channel_email')

        account.extend_trial!(3)
        account.reload

        expect(account.feature_enabled?('channel_voice')).to be(true)
        expect(account.feature_enabled?('captain_integration')).to be(true)
        expect(account.feature_enabled?('channel_email')).to be(false)
        expect(account.limits['agents']).to eq(7)
      end

      it 'sees the legacy list as granted by a trial that has no list in its snapshot' do
        legacy_trial_account

        expect(account.granted_trial_features).to eq(Account::LEGACY_TRIAL_FEATURES)
        expect(create(:account).granted_trial_features).to eq([])
      end

      it 'keeps the legacy grant when such a trial is started again' do
        legacy_trial_account
        account.update!(custom_attributes: account.custom_attributes.merge('trial_expires_at' => 1.day.from_now.iso8601))

        account.activate_trial!(3)

        expect(account.custom_attributes['trial_snapshot']['trial_features']).to include(*Account::LEGACY_TRIAL_FEATURES, *Account::TRIAL_FEATURES)
      end
    end

    describe 'reversible trial' do
      def expire_in_the_past!(acc)
        acc.update!(custom_attributes: acc.custom_attributes.merge('trial_expires_at' => 1.hour.ago.iso8601))
      end

      it 'remembers what the account had before the trial' do
        account.update!(limits: { 'agents' => 7, 'storage_bytes' => 5_000 })
        account.activate_trial!(3)

        snapshot = account.custom_attributes['trial_snapshot']
        expect(snapshot['limits']).to eq('agents' => 7)
        expect(snapshot['features']).to be_an(Array)
        expect(snapshot['features']).not_to include('channel_voice')
      end

      it 'keeps the first snapshot when the trial is activated again' do
        account.activate_trial!(3)
        first = account.custom_attributes['trial_snapshot']
        account.activate_trial!(3)

        expect(account.custom_attributes['trial_snapshot']).to eq(first)
      end

      it 'takes back only what the trial added, and keeps features granted by hand' do
        account.enable_features('channel_email', 'crm')
        account.save!
        account.activate_trial!(3)
        account.enable_features!('linear_integration')

        account.expire_trial!
        account.reload

        expect(account.feature_enabled?('channel_voice')).to be(false)
        expect(account.feature_enabled?('captain_integration')).to be(false)
        expect(account.feature_enabled?('channel_email')).to be(true)
        expect(account.feature_enabled?('crm')).to be(true) # had it before the trial, so it stays
        expect(account.feature_enabled?('linear_integration')).to be(true)
        expect(account.limits).to include('agents' => 0, 'inboxes' => 0)
        expect(account.custom_attributes['trial_expired_at']).to be_present
      end

      it 'gives the trial features and the previous limits back when an expired trial is extended' do
        account.update!(limits: { 'agents' => 7 })
        account.activate_trial!(3)
        account.expire_trial!

        account.extend_trial!(3)
        account.reload

        expect(account.trial_active?).to be(true)
        expect(account.custom_attributes).not_to have_key('trial_expired_at')
        expect(account.feature_enabled?('channel_voice')).to be(true)
        expect(account.limits['agents']).to eq(7)
        expect(account.limits).not_to have_key('inboxes')
      end

      it 'is idempotent and never wipes the original limits when ended twice' do
        account.update!(limits: { 'agents' => 7 })
        account.activate_trial!(3)
        2.times { account.expire_trial! }

        expect(account.custom_attributes['trial_snapshot']['limits']).to eq('agents' => 7)
      end

      it 'does not qualify or mutate a hand-managed trial without a feature snapshot' do
        account.enable_features!('channel_voice')
        account.update!(custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 1.day.ago.iso8601 },
                        limits: { 'agents' => 4 })

        expect(account.expire_trial!).to be(false)
        expect(account.reload.feature_enabled?('channel_voice')).to be(true)
        expect(account.limits).to eq('agents' => 4)
        expect(account.custom_attributes).not_to have_key('trial_snapshot')
        expect { account.extend_trial!(3) }.to raise_error(ArgumentError, 'Only a snapshot-backed trial can be extended')
        expect(account.reload.limits).to eq('agents' => 4)
      end

      it 'does not expire a stale selection after the account was upgraded to a paid plan' do
        account.activate_trial!(3)
        expire_in_the_past!(account)
        stale_selection = Account.find(account.id)
        account.update!(custom_attributes: account.custom_attributes.merge('plan_type' => 'growth'))

        expect(stale_selection.expire_trial!(only_if_expired: true)).to be(false)
        expect(account.reload.custom_attributes['plan_type']).to eq('growth')
        expect(account.custom_attributes['trial_expired_at']).to be_nil
        expect(account.feature_enabled?('channel_voice')).to be(true)
      end
    end

    describe Accounts::ExpireTrialsJob do
      def trial_account(snapshot: true, expires: 1.hour.ago, plan: 'trial')
        acc = create(:account)
        snapshot ? acc.activate_trial!(3) : acc.update!(custom_attributes: { 'plan_type' => 'trial' })
        acc.update!(custom_attributes: acc.custom_attributes.merge('plan_type' => plan, 'trial_expires_at' => expires.iso8601))
        acc
      end

      it 'ends only the activated trials that have run out' do
        ran_out = trial_account
        still_running = trial_account(expires: 2.days.from_now)
        hand_managed = trial_account(snapshot: false)
        upgraded = trial_account(plan: 'growth')

        described_class.perform_now

        expect(ran_out.reload.custom_attributes['trial_expired_at']).to be_present
        expect(ran_out.feature_enabled?('channel_voice')).to be(false)
        expect(still_running.reload.custom_attributes['trial_expired_at']).to be_nil
        expect(still_running.feature_enabled?('channel_voice')).to be(true)
        expect(hand_managed.reload.custom_attributes['trial_expired_at']).to be_nil
        expect(upgraded.reload.custom_attributes['trial_expired_at']).to be_nil
        expect(upgraded.feature_enabled?('channel_voice')).to be(true)
      end

      it 'does not process an already ended trial again' do
        acc = trial_account
        described_class.perform_now
        ended_at = acc.reload.custom_attributes['trial_expired_at']

        allow_any_instance_of(Account).to receive(:expire_trial!).and_call_original # rubocop:disable RSpec/AnyInstance
        described_class.perform_now

        expect(acc.reload.custom_attributes['trial_expired_at']).to eq(ended_at)
      end

      it 'keeps going when one account fails' do
        first = trial_account
        second = trial_account
        allow_any_instance_of(Account).to receive(:expire_trial!).and_wrap_original do |original, *args, **kwargs| # rubocop:disable RSpec/AnyInstance
          raise StandardError, 'boom' if original.receiver.id == first.id

          original.call(*args, **kwargs)
        end

        expect { described_class.perform_now }.not_to raise_error
        expect(second.reload.custom_attributes['trial_expired_at']).to be_present
        expect(first.reload.custom_attributes['trial_expired_at']).to be_nil
      end

      it 'runs on the housekeeping queue' do
        expect(described_class.new.queue_name).to eq('housekeeping')
      end
    end
  end
end
