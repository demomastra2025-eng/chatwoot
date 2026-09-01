require 'rails_helper'

RSpec.describe Account, type: :model do
  describe 'overflow feature flags' do
    let(:account) { create(:account) }

    it 'preserves the legacy bitmask position for advanced_assignment' do
      account.disable_features!('scheduling', 'scheduling_finance')
      account.update_column(:feature_flags, 1 << 62)

      account.reload

      expect(account.feature_enabled?('advanced_assignment')).to be(true)
      expect(account.feature_enabled?('scheduling')).to be(false)
      expect(account.feature_enabled?('scheduling_finance')).to be(false)
    end

    it 'persists scheduling_finance in the overflow store' do
      expect { account.enable_features!('scheduling_finance') }.not_to raise_error

      expect(account.reload.feature_enabled?('scheduling_finance')).to be(true)
      expect(account.selected_feature_flags).to include(:scheduling_finance)
    end

    it 'supports bulk selected_feature_flags updates across bitmask and overflow features' do
      account.selected_feature_flags = %i[crm scheduling scheduling_finance]
      account.save!

      account.reload

      expect(account.feature_enabled?('crm')).to be(true)
      expect(account.feature_enabled?('scheduling')).to be(true)
      expect(account.feature_enabled?('scheduling_finance')).to be(true)
    end

    it 'keeps new scheduling flags out of the legacy bitmask map' do
      expect(Featurable::FEATURE_POSITIONS).not_to have_key('scheduling')
      expect(Featurable::FEATURE_POSITIONS).not_to have_key('scheduling_finance')
      expect(Featurable::OVERFLOW_FEATURE_NAMES).to include('scheduling', 'scheduling_finance')
    end

    it 'keeps the retired feature slot without exposing it as an active feature' do
      expect(Featurable::LEGACY_BITMASK_FEATURE_NAMES.fetch(53)).to eq('retired_feature_54')
      expect(Featurable::FEATURE_NAMES).not_to include('retired_feature_54')
      expect(Featurable::FEATURE_POSITIONS.fetch('advanced_search_indexing')).to eq(55)
    end

    it 'supports explicit legacy setters used by enterprise extensions' do
      account.feature_advanced_assignment = true
      account.save!

      expect(account.reload.feature_enabled?('advanced_assignment')).to be(true)
    end

    it 'ignores stale unknown account-level defaults without breaking account creation' do
      InstallationConfig.where(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS').delete_all
      create(
        :installation_config,
        name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS',
        value: [
          { 'name' => 'removed_feature', 'enabled' => true },
          { 'name' => 'scheduling', 'enabled' => true }
        ]
      )

      created_account = nil
      expect { created_account = create(:account) }.not_to raise_error
      expect(created_account.feature_enabled?('removed_feature')).to be(false)
      expect(created_account.feature_enabled?('scheduling')).to be(true)
    end
  end
end
