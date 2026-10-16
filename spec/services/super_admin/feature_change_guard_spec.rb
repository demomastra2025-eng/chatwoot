require 'rails_helper'

RSpec.describe SuperAdmin::FeatureChangeGuard do
  let(:account) { create(:account) }
  let(:guard) { described_class.new(account) }

  def reasons(requested)
    guard.violations(requested).to_h { |violation| [violation.flag, violation.reason] }
  end

  describe 'a function of the base or of a module' do
    it 'may be switched on and off' do
      account.disable_features!('crm', 'sla')

      expect(reasons('crm' => true, 'sla' => true)).to be_empty
      account.enable_features!('crm', 'sla')
      expect(reasons('crm' => false, 'sla' => false)).to be_empty
    end
  end

  describe 'a function no plan ever enables' do
    it 'cannot be switched on while it is off' do
      account.disable_features!('scheduling_finance', 'saml')

      expect(reasons('scheduling_finance' => true, 'saml' => true)).to eq('scheduling_finance' => :never_enabled, 'saml' => :never_enabled)
    end

    it 'does not block a clinic that already has it: asking for the state it has is no change' do
      account.enable_features!('scheduling_finance')

      expect(reasons('scheduling_finance' => true)).to be_empty
      expect(guard.changes('scheduling_finance' => true)).to be_empty
    end

    it 'may be switched off' do
      account.enable_features!('scheduling_finance')

      expect(reasons('scheduling_finance' => false)).to be_empty
    end
  end

  describe 'a function that must stay on' do
    it 'cannot be switched off while it is on' do
      account.enable_features!('agent_management', 'inbox_management')

      expect(reasons('agent_management' => false, 'inbox_management' => false)).to eq(
        'agent_management' => :locked_on, 'inbox_management' => :locked_on
      )
    end

    it 'may stay on, and may be switched on when it is off' do
      account.enable_features!('agent_management')
      account.disable_features!('team_management')

      expect(reasons('agent_management' => true, 'team_management' => true)).to be_empty
    end
  end

  describe 'an internal function' do
    it 'cannot be changed either way' do
      account.enable_features!('inbox_view')
      account.disable_features!('crm_v2')

      expect(reasons('inbox_view' => false, 'crm_v2' => true)).to eq('inbox_view' => :internal, 'crm_v2' => :internal)
    end

    it 'may be sent unchanged' do
      account.enable_features!('inbox_view')

      expect(reasons('inbox_view' => true)).to be_empty
    end

    it 'may be changed when it is an owner decision' do
      account.disable_features!(*SuperAdmin::FineTuning::OWNER_DECISION_FLAGS)

      expect(reasons(SuperAdmin::FineTuning::OWNER_DECISION_FLAGS.index_with { true })).to be_empty
      account.enable_features!(*SuperAdmin::FineTuning::OWNER_DECISION_FLAGS)
      expect(reasons(SuperAdmin::FineTuning::OWNER_DECISION_FLAGS.index_with { false })).to be_empty
    end
  end

  describe 'a function that no place of the plans names' do
    it 'cannot be changed' do
      allow(Accounts::Plans).to receive(:classified_features).and_return(Accounts::Plans.classified_features - ['crm'])
      account.disable_features!('crm')

      expect(reasons('crm' => true)).to eq('crm' => :internal)
    end
  end

  describe 'a clinic that is being created' do
    it 'is judged against an empty clinic' do
      guard = described_class.new(Account.new)

      expect(guard.violations('crm' => true, 'saml' => true).map(&:flag)).to eq(['saml'])
      expect(guard.violations('agent_management' => false)).to be_empty
    end
  end

  describe '#message' do
    it 'is nil when everything is allowed' do
      expect(guard.message('crm' => true)).to be_nil
    end

    it 'says in Russian that nothing was saved and why, for each refused function' do
      account.enable_features!('agent_management')
      account.disable_features!('saml', 'inbox_view')

      message = guard.message('saml' => true, 'agent_management' => false, 'inbox_view' => true)

      expect(message).to start_with('Изменения не сохранены.')
      expect(message).to include('Функцию «Единый вход SAML» нельзя включить: ни один тариф её не включает.')
      expect(message).to include('Функцию «Управление операторами» нельзя выключить: она всегда нужна клинике.')
      expect(message).to include('Функцию «Представление входящих» нельзя менять здесь: это служебная настройка платформы.')
    end
  end
end
