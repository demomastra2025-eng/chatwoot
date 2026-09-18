require 'rails_helper'

RSpec.describe AccessControl::ReleaseGate do
  describe '.configuration' do
    it 'defaults both release gates to disabled' do
      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: nil, ACCESS_ROLE_ASSIGNMENTS_ENABLED: nil) do
        expect(described_class.configuration).to have_attributes(
          mutations_enabled: false,
          assignments_enabled: false,
          errors: []
        )
      end
    end

    it 'accepts the staged mutations-then-assignments configuration' do
      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'true', ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
        expect(described_class.configuration).to have_attributes(
          mutations_enabled: true,
          assignments_enabled: true,
          errors: []
        )
      end
    end

    it 'rejects normalized assignments without normalized mutations' do
      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'false', ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
        expect(described_class.configuration).to have_attributes(
          mutations_enabled: false,
          assignments_enabled: true,
          errors: ['ACCESS_ROLE_ASSIGNMENTS_ENABLED requires ACCESS_ROLE_MUTATIONS_ENABLED=true']
        )
        expect { described_class.assignments_enabled? }
          .to raise_error(described_class::InvalidConfiguration, /requires ACCESS_ROLE_MUTATIONS_ENABLED/)
      end
    end

    it 'rejects ambiguous boolean values instead of silently disabling a gate' do
      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: '1', ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'false') do
        expect(described_class.configuration.errors).to eq(
          ['ACCESS_ROLE_MUTATIONS_ENABLED must be exactly true or false']
        )
        expect { described_class.mutations_enabled? }
          .to raise_error(described_class::InvalidConfiguration, /must be exactly true or false/)
      end
    end
  end

  describe '.status' do
    it 'reports modes and durable canonical mutation footprint without changing data' do
      legacy_account = create(:account)
      enforced_account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: enforced_account)
      create(:account_user, account: enforced_account, role: :agent)
      AccessControl::ModeTransition.call(account: enforced_account, to: :shadow)
      AccessControl::ModeTransition.call(account: enforced_account, to: :enforced)
      enforced_account.update!(access_role_canonicalized_at: 1.minute.ago)

      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'true', ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'false') do
        status = described_class.status

        expect(status).to have_attributes(
          valid: true,
          mutations_enabled: true,
          assignments_enabled: false,
          canonical_role_count: 0,
          canonicalized_account_count: 1
        )
        expect(status.account_mode_counts).to include('legacy' => 1, 'enforced' => 1)
      end

      expect(legacy_account.reload).to be_access_control_mode_legacy
      expect(enforced_account.reload).to be_access_control_mode_enforced
    end
  end
end
