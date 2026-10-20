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

  # The «Входит: …» line of a module card: every function once, and a second version of a function is not named again
  describe '.module_feature_labels' do
    it 'names the functions of a module without repeating a name' do
      Accounts::Plans.module_keys.each do |key|
        labels = described_class.module_feature_labels(key)

        expect(labels).not_to be_empty
        expect(labels).to eq(labels.uniq), "#{key}: #{labels.inspect}"
        expect(labels.grep(/версия|v2/i)).to be_empty, "#{key}: #{labels.inspect}"
        expect(labels).to all(be_present)
      end
    end

    it 'says the AI agents once, and the mailings once' do
      expect(described_class.module_feature_labels('ai_agents')).to eq(['ИИ-агенты', 'Задачи ИИ-агентов', 'Умный поиск по базе знаний'])
      expect(described_class.module_feature_labels('broadcasts')).to eq(['Рассылки (в том числе в WhatsApp)'])
    end

    it 'leaves the other modules as they were named' do
      expect(described_class.module_feature_labels('quality')).to eq(['SLA', 'Журнал аудита', 'Заметки к оценкам клиентов'])
    end

    it 'does not lose a function: a function that is hidden has another that stands for it' do
      hidden = Accounts::Plans.module_keys.flat_map do |key|
        Accounts::Plans.module_features(key).select do |flag|
          I18n.exists?("super_admin.plans.hint_labels.#{flag}") && I18n.t("super_admin.plans.hint_labels.#{flag}").blank?
        end
      end

      expect(hidden).to match_array(%w[captain_integration_v2 whatsapp_campaign])
    end
  end
end
