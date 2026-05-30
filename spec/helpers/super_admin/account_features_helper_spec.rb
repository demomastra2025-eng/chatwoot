require 'rails_helper'

RSpec.describe SuperAdmin::AccountFeaturesHelper do
  describe '.filtered_features' do
    before do
      allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(false)
    end

    it 'keeps companies available for self-hosted Super Admin account feature management' do
      companies_feature = described_class.account_features.find { |feature| feature['name'] == 'companies' }

      expect(companies_feature).to include(
        'display_name' => 'Companies',
        'chatwoot_internal' => false
      )
      expect(described_class.filtered_features({ 'companies' => false })).to include(%w[companies Companies] => false)
    end
  end
end
