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

  describe '.feature_label' do
    it 'has a Russian name for every flag of features.yml' do
      missing = Featurable::FEATURE_NAMES.reject { |name| I18n.exists?("super_admin.features.#{name}", :ru) }

      expect(missing).to be_empty
    end

    it 'names the flags the plans talk about in plain Russian' do
      expect(described_class.feature_label('captain_integration')).to eq('ИИ-агенты')
      expect(described_class.feature_label('channel_voice')).to eq('Телефония')
      expect(described_class.feature_label('scheduling_finance')).to eq('Финансы записи')
    end

    it 'does not call anything a «касание» or a touch: those words are not shown to anyone' do
      labels = I18n.t('super_admin.features', locale: :ru).values

      expect(labels.grep(/касани|touch/i)).to be_empty
      expect(described_class.feature_label('deferred_touch_materialization')).to eq('Отложенная обработка событий')
    end

    it 'falls back to a readable name for a flag nobody translated' do
      expect(described_class.feature_label('some_new_flag')).to eq('Some new flag')
    end
  end
end
