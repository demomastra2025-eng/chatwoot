require 'rails_helper'

RSpec.describe SuperAdmin::FineTuning do
  let(:account) do
    create(:account).tap { |record| Accounts::ApplyPlan.new(account: record, modules: []).call }
  end
  let(:tuning) { described_class.new(account.reload) }
  let(:names) { tuning.flag_names }

  def switch(name)
    tuning.groups.flat_map(&:switches).find { |candidate| candidate.name == name }
  end

  it 'offers every flag of the base and of the modules that the application knows' do
    planned = Accounts::Plans.base_features + Accounts::Plans.module_keys.flat_map { |key| Accounts::Plans.module_features(key) }

    expect(names).to match_array(planned & Featurable::FEATURE_NAMES)
  end

  it 'never offers always-on, never-enabled or internal flags' do
    hidden = Accounts::Plans.locked_on + Accounts::Plans.never_enabled + Accounts::Plans.internal

    expect(names & hidden).to be_empty
    expect(names).not_to include('agent_management', 'team_management', 'inbox_management', 'labels', 'custom_attributes')
    expect(names).not_to include('custom_roles', 'saml', 'scheduling_finance')
  end

  it 'groups the base by area, then one group per module' do
    expect(tuning.groups.map(&:title)).to eq(
      ['Каналы и почта', 'Телефония', 'Диалоги и автоматизация', 'CRM и запись', 'ИИ-агенты', 'Рассылки', 'Контроль качества', 'Расширения']
    )
  end

  it 'puts every flag into exactly one group' do
    expect(names.uniq.size).to eq(names.size)
  end

  it 'names every switch with its Russian name' do
    switches = tuning.groups.flat_map(&:switches)

    expect(switches.map(&:label)).to eq(switches.map { |item| I18n.t("super_admin.features.#{item.name}") })
    expect(switches.map(&:label).grep_v(/\p{Cyrillic}/)).to all(match(/\A[A-Z]{2,4}\z/)) # acronyms: CRM, SLA
  end

  it 'puts a base flag that has no area into «Прочее» so it still gets a switch' do
    allow(Accounts::Plans).to receive(:base_features).and_return(Accounts::Plans.base_features + ['ip_lookup'])

    other = tuning.groups.find { |group| group.title == 'Прочее' }

    expect(other.switches.map(&:name)).to eq(['ip_lookup'])
  end

  it 'shows the state of the clinic and marks what differs from the plan as manual' do
    account.enable_features!('sla')
    account.disable_features!('crm')

    expect(switch('sla')).to have_attributes(enabled: true, manual: true)
    expect(switch('crm')).to have_attributes(enabled: false, manual: true)
    expect(switch('reports')).to have_attributes(enabled: true, manual: false)
    expect(tuning.groups.flat_map(&:switches).count(&:manual)).to eq(2)
  end

  it 'marks nothing as manual for a clinic without a plan' do
    plain = create(:account)

    expect(described_class.new(plain).groups.flat_map(&:switches).none?(&:manual)).to be(true)
  end

  describe '#never_enabled_labels' do
    it 'names the flags no plan enables, without the deprecated ones' do
      labels = tuning.never_enabled_labels

      expect(labels).to include('Роли доступа', 'Единый вход SAML', 'Финансы записи')
      expect(labels.join).not_to include('устарело')
    end
  end
end
