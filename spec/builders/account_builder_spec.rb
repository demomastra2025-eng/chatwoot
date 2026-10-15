# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountBuilder do
  let(:email) { 'user@example.com' }
  let(:user_password) { 'Password123!' }
  let(:account_name) { 'Test Account' }
  let(:user_full_name) { 'Test User' }
  let(:validation_service) { instance_double(Account::SignUpEmailValidationService, perform: true) }
  let(:account_builder) do
    described_class.new(
      account_name: account_name,
      email: email,
      user_full_name: user_full_name,
      user_password: user_password,
      confirmed: true
    )
  end

  # Mock the email validation service
  before do
    allow(Account::SignUpEmailValidationService).to receive(:new).with(email).and_return(validation_service)
  end

  describe '#perform' do
    context 'when valid params are passed' do
      it 'creates a new account with correct name' do
        _user, account = account_builder.perform
        expect(account).to be_an(Account)
        expect(account.name).to eq(account_name)
      end

      it 'creates a new confirmed user with correct details' do
        user, _account = account_builder.perform
        expect(user).to be_a(User)
        expect(user.email).to eq(email)
        expect(user.name).to eq(user_full_name)
        expect(user.confirmed?).to be(true)
      end

      context 'when the user full name is blank' do
        let(:user_full_name) { nil }

        it 'falls back to the part of the email before the at sign' do
          user, _account = account_builder.perform

          expect(user).to be_persisted
          expect(user.name).to eq('user')
        end
      end

      it 'links user to account as administrator' do
        user, account = account_builder.perform
        expect(user.account_users.first.role).to eq('administrator')
        expect(user.accounts.first).to eq(account)
      end

      it 'increments the counts of models' do
        expect do
          account_builder.perform
        end.to change(Account, :count).by(1)
           .and change(User, :count).by(1)
           .and change(AccountUser, :count).by(1)
      end

      describe 'the plan of a new account' do
        let(:plans) { Accounts::Plans }
        let(:account) { account_builder.perform.last.reload }

        it 'gets the base plan, then a trial of the base plus the trial modules' do
          expect(account.custom_attributes).to include('plan' => 'base', 'plan_modules' => [], 'plan_version' => plans.version,
                                                       'plan_type' => 'trial')
          expect(account.trial_active?).to be(true)
          expect(account.trial_expires_at).to be_within(1.minute).of(plans.trial_days.days.from_now)
          expect(account.enabled_features.keys).to include(*plans.base_features, *plans.locked_on, *plans.module_features('ai_agents'))
        end

        it 'does not get the flags that no plan offers' do
          expect(account.enabled_features.keys).not_to include(*plans.never_enabled)
        end

        it 'is not trapped by the global defaults of 500 conversations and no channels besides the website widget' do
          expect(account.limits).to include('conversations' => ChatwootApp.max_limit, 'non_web_inboxes' => ChatwootApp.max_limit)
        end

        it 'takes the base flags into the trial snapshot, so the end of the trial removes only the modules' do
          expect(account.custom_attributes['trial_snapshot']['features']).to include(*plans.base_features)
          expect(account.custom_attributes['trial_snapshot']['features']).not_to include(*plans.module_features('ai_agents'))

          account.expire_trial!
          account.reload

          expect(account.enabled_features.keys).to include(*plans.base_features)
          expect(account.enabled_features.keys).not_to include(*plans.module_features('ai_agents'))
        end

        it 'leaves an audit entry for the plan, written by the system' do
          expect(Audited::Audit.where(auditable_id: account.id, action: 'apply_plan').last).to have_attributes(user_id: nil, comment: 'system')
        end
      end
    end
  end
end
