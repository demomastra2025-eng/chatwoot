require 'rails_helper'

RSpec.describe AccessControl::ModeTransition do
  describe '.call' do
    it 'allows only the staged transition sequence' do
      account = create(:account)

      expect { described_class.call(account: account, to: :enforced) }
        .to raise_error(described_class::InvalidTransition, /legacy to enforced/)

      shadow_result = described_class.call(account: account, to: :shadow)
      legacy_result = described_class.call(account: account, to: :legacy)

      expect(shadow_result).to have_attributes(from: 'legacy', to: 'shadow', changed: true)
      expect(legacy_result).to have_attributes(from: 'shadow', to: 'legacy', changed: true)
    end

    it 'does not write when the account is already in the requested mode' do
      account = create(:account)

      result = described_class.call(account: account, to: :legacy)

      expect(result).to have_attributes(from: 'legacy', to: 'legacy', changed: false, readiness: nil)
      expect(account.previous_changes).not_to include('access_control_mode')
    end

    it 'rejects enforcement until compatibility and system presets are ready' do
      account = create(:account)
      described_class.call(account: account, to: :shadow)

      expect { described_class.call(account: account, to: :enforced) }
        .to raise_error(described_class::NotReady) { |error| expect(error.readiness.missing_system_roles).not_to be_empty }
      expect(account.reload).to be_access_control_mode_shadow
    end

    it 'enforces a ready account and supports immediate rollback to shadow' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      create(:account_user, account: account, role: :agent)
      described_class.call(account: account, to: :shadow)

      enforced = described_class.call(account: account, to: :enforced)
      rolled_back = described_class.call(account: account, to: :shadow)

      expect(enforced.readiness).to be_ready
      expect(enforced).to have_attributes(from: 'shadow', to: 'enforced', changed: true)
      expect(rolled_back).to have_attributes(from: 'enforced', to: 'shadow', changed: true)
      expect(account.reload).to be_access_control_mode_shadow
    end

    it 'rejects unknown modes before locking the account' do
      account = create(:account)

      expect { described_class.call(account: account, to: :unknown) }
        .to raise_error(described_class::InvalidTransition, /Unsupported access control mode/)
    end
  end
end
