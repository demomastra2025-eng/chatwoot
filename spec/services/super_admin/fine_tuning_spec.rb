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
    expect(names).not_to include('custom_roles', 'saml', 'captain_scheduling_grounding_guard')
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

      expect(labels).to include('Роли доступа', 'Единый вход SAML', 'Проверка записи ИИ-агентом')
      expect(labels.join).not_to include('устарело')
    end
  end

  describe '#service_switches' do
    it 'has a switch for every owner decision, none of them in the plan switches' do
      switches = tuning.service_switches

      expect(switches.map(&:name)).to eq(described_class::OWNER_DECISION_FLAGS)
      expect(switches.map(&:label)).to eq(['Один чат на контакт', 'Автораспределение, версия 2', 'Свой ключ OpenRouter у аккаунта'])
      expect(described_class::OWNER_DECISION_FLAGS & names).to be_empty
    end

    it 'says in a line what each switch does and asks a question for both directions, naming the clinic' do
      account.update!(name: 'Аккаунт Алатау')

      tuning.service_switches.each do |switch|
        expect(switch.hint).to match(/\p{Cyrillic}/)
        expect(switch.confirm_on).to include('Аккаунт Алатау').and match(/\p{Cyrillic}/)
        expect(switch.confirm_off).to include('Аккаунт Алатау').and match(/\p{Cyrillic}/)
      end
    end

    it 'shows the state of the clinic' do
      account.enable_features!('communication_threads')

      states = tuning.service_switches.to_h { |switch| [switch.name, switch.enabled] }

      expect(states).to eq('communication_threads' => true, 'assignment_v2' => false, 'captain_openrouter_byok' => false)
    end

    it 'leaves out a decision flag that the application no longer has' do
      account # created while every flag still exists
      stub_const('Featurable::FEATURE_NAMES', Featurable::FEATURE_NAMES - ['communication_threads'])

      expect(tuning.service_switches.map(&:name)).not_to include('communication_threads')
    end
  end
end
