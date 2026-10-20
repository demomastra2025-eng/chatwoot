# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Super admin account plans', type: :request do
  let!(:super_admin) { create(:super_admin) }
  let!(:account) { create(:account).tap { |record| record.disable_features!(*Featurable::FEATURE_NAMES) } }

  def admin_request_locale
    ENV.fetch('DEFAULT_LOCALE', I18n.default_locale)
  end

  def flash_text(key, **)
    I18n.t("super_admin.accounts.flashes.#{key}", locale: admin_request_locale, **)
  end

  describe 'POST /super_admin/accounts/:id/apply_plan' do
    it 'sends an unauthenticated visitor to the login and changes nothing' do
      post "/super_admin/accounts/#{account.id}/apply_plan", params: { modules: %w[ai_agents] }

      expect(response).to have_http_status(:redirect)
      expect(account.reload.custom_attributes).not_to have_key('plan')
      expect(account.feature_enabled?('crm')).to be(false)
    end

    it 'does not let a clinic administrator reach it' do
      sign_in(create(:user, account: account, role: :administrator))

      post "/super_admin/accounts/#{account.id}/apply_plan", params: { modules: %w[ai_agents] }

      expect(response).to have_http_status(:redirect)
      expect(account.reload.custom_attributes).not_to have_key('plan')
    end

    it 'applies the base alone when no module is chosen' do
      sign_in(super_admin, scope: :super_admin)

      post "/super_admin/accounts/#{account.id}/apply_plan"

      expect(response).to have_http_status(:redirect)
      expect(flash[:notice]).to eq(flash_text(:plan_applied, plan: 'База'))
      account.reload
      expect(account.custom_attributes).to include('plan' => 'base', 'plan_modules' => [])
      expect(account.feature_enabled?('crm')).to be(true)
      expect(account.feature_enabled?('captain_integration')).to be(false)
    end

    it 'applies the chosen modules, says so in Russian and records who did it' do
      sign_in(super_admin, scope: :super_admin)

      post "/super_admin/accounts/#{account.id}/apply_plan", params: { modules: %w[ai_agents broadcasts] }

      expect(flash[:notice]).to eq(flash_text(:plan_applied, plan: 'База + ИИ-агенты + Рассылки'))
      account.reload
      expect(account.custom_attributes['plan_modules']).to eq(%w[ai_agents broadcasts])
      expect(account.feature_enabled?('captain_integration')).to be(true)
      expect(account.feature_enabled?('campaigns')).to be(true)
      audit = Audited::Audit.where(auditable_id: account.id, action: 'apply_plan').last
      expect(audit).to have_attributes(user_id: super_admin.id, comment: 'super_admin')
      expect(audit.remote_address).to be_present
    end

    it 'refuses an unknown module and changes nothing' do
      sign_in(super_admin, scope: :super_admin)

      post "/super_admin/accounts/#{account.id}/apply_plan", params: { modules: %w[ai_agents ghost] }

      expect(flash[:alert]).to eq(flash_text(:plan_unknown_module))
      expect(account.reload.custom_attributes).not_to have_key('plan')
      expect(account.feature_enabled?('captain_integration')).to be(false)
    end

    it 'refuses a malformed modules param' do
      sign_in(super_admin, scope: :super_admin)

      post "/super_admin/accounts/#{account.id}/apply_plan", params: { modules: { ai_agents: '1' } }

      expect(flash[:alert]).to eq(flash_text(:plan_unknown_module))
      expect(account.reload.custom_attributes).not_to have_key('plan')
    end

    it 'tells the operator when the plan could not be written' do
      sign_in(super_admin, scope: :super_admin)
      allow_any_instance_of(Accounts::ApplyPlan).to receive(:call).and_raise(StandardError, 'boom') # rubocop:disable RSpec/AnyInstance

      post "/super_admin/accounts/#{account.id}/apply_plan", params: { modules: %w[ai_agents] }

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(flash_text(:plan_apply_failed))
    end

    it 'keeps the trial of the account untouched' do
      account.activate_trial!(3)
      trial_state = account.reload.custom_attributes.slice('plan_type', 'trial_expires_at', 'trial_snapshot')
      sign_in(super_admin, scope: :super_admin)

      post "/super_admin/accounts/#{account.id}/apply_plan", params: { modules: %w[ai_agents] }

      expect(account.reload.custom_attributes).to include(trial_state)
    end
  end

  describe 'GET /super_admin/accounts/:id/plan_preview' do
    it 'sends an unauthenticated visitor to the login' do
      get "/super_admin/accounts/#{account.id}/plan_preview", params: { modules: %w[ai_agents] }

      expect(response).to have_http_status(:redirect)
    end

    it 'returns the diff as JSON and writes nothing', :aggregate_failures do
      account.enable_features!('captain_scheduling_grounding_guard')
      stored = Account.find(account.id).attributes
      sign_in(super_admin, scope: :super_admin)

      expect do
        get "/super_admin/accounts/#{account.id}/plan_preview", params: { modules: %w[ai_agents] }
      end.not_to change(Audited::Audit, :count)

      expect(response).to have_http_status(:success)
      expect(response.media_type).to eq('application/json')
      body = response.parsed_body
      expect(body).to include('plan' => 'base', 'modules' => %w[ai_agents], 'plan_version' => Accounts::Plans.version, 'changed' => true)
      expect(body['enable']).to include('crm', 'captain_integration')
      expect(body['disable']).to eq(%w[captain_scheduling_grounding_guard])
      expect(body['limits']).to include('conversations' => { 'from' => nil, 'to' => ChatwootApp.max_limit })
      expect(Account.find(account.id).attributes).to eq(stored)
    end

    it 'previews the base alone when no module is given' do
      sign_in(super_admin, scope: :super_admin)

      get "/super_admin/accounts/#{account.id}/plan_preview"

      expect(response.parsed_body).to include('modules' => [])
      expect(response.parsed_body['enable']).not_to include('captain_integration')
    end

    it 'answers 422 with a Russian message for an unknown module' do
      sign_in(super_admin, scope: :super_admin)

      get "/super_admin/accounts/#{account.id}/plan_preview", params: { modules: %w[ghost] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq(flash_text(:plan_unknown_module))
    end
  end

  # The end of a trial that nobody chose for the clinic closed operators and channels (limits 0): the plan gives them back, and the
  # preview, the card and the entry of the audit log say so (the states of the trial: see spec/services/accounts/apply_plan_spec.rb)
  describe 'the plan of a clinic whose trial has ended' do
    let(:card_path) { "/super_admin/accounts/#{account.id}" }

    def page = Nokogiri::HTML(response.body)

    before do
      account.update!(limits: { 'agents' => 5, 'inboxes' => 3 })
      account.activate_trial!(3)
      account.expire_trial!
      sign_in(super_admin, scope: :super_admin)
    end

    it 'says in the preview that the limits come back, and shows them', :aggregate_failures do
      get "#{card_path}/plan_preview", params: { modules: [], fragment: 1 }

      preview = page.at_css('[data-testid="plan-preview"]')
      expect(preview['data-changed']).to eq('true')
      note = preview.at_css('[data-preview-note="trial_limits_restored"]').text.squish
      expect(note).to eq('Пробный период закончился и закрыл операторов и каналы (лимиты стоят на 0). '                          'Тариф сам вернёт им лимиты, какие были до пробного периода.')
      limits = preview.at_css('[data-preview="limits"]').text.squish
      expect(limits).to include('Операторы: 0 → 5')
    end

    it 'gives the limits back when the plan is applied, and writes them in the audit log' do
      post "#{card_path}/apply_plan"

      expect(account.reload.limits).to include('agents' => 5, 'inboxes' => 3)
      expect(Audited::Audit.where(action: 'apply_plan').last.audited_changes['limits']).to include('agents' => { 'from' => 0, 'to' => 5 })
    end

    it 'says on the card of the clinic that the plan gives the limits back, until it has' do
      get card_path
      expect(page.at_css('[data-testid="trial-limits-held"]').text.squish).to include('лимиты стоят на 0', 'Нажмите «Назначить базу и вернуть лимиты» в блоке «Тариф»')
      expect(page.at_css('form[data-plan-form] button[data-plan-submit]').text.squish).to eq('Назначить базу и вернуть лимиты')

      post "#{card_path}/apply_plan"
      get card_path

      expect(page.at_css('[data-testid="trial-limits-held"]')).to be_nil
    end

    it 'does not say it for a clinic whose trial kept the limits' do
      other = create(:account).tap { |record| record.disable_features!(*Featurable::FEATURE_NAMES) }
      Accounts::ApplyPlan.new(account: other, modules: []).call
      other.activate_trial!(3, keep_limits: true)
      other.expire_trial!

      get "/super_admin/accounts/#{other.id}"

      expect(page.at_css('[data-testid="trial-limits-held"]')).to be_nil
    end
  end

  # A clinic that signed up by itself (or came through the Platform API) has «База» from its first minute: AccountBuilder applies it
  # before the trial starts. So when the trial ends the plan is "assigned" and its modules are the ones the form shows, and the card
  # must still offer to give the operator and channel limits back.
  describe 'the plan of a clinic that signed up by itself, after its trial' do
    let(:card_path) { "/super_admin/accounts/#{signed_up.id}" }
    let(:owner) { create(:user) }
    let(:signed_up) do
      AccountBuilder.new(account_name: 'Самозапись', email: owner.email, user: owner).perform.last.tap do |record|
        record.update!(limits: record.limits.to_h.merge('agents' => 5, 'inboxes' => 3)) if limits_before_trial
      end
    end
    let(:limits_before_trial) { false }

    def page = Nokogiri::HTML(response.body)

    def plan_form = page.at_css('form[data-plan-form]')

    def plan_button = plan_form.at_css('button[data-plan-submit]')

    before { sign_in(super_admin, scope: :super_admin) }

    it 'has «База» assigned when the trial starts, and the end of the trial closes operators and channels' do
      signed_up.expire_trial!

      expect(signed_up.reload.custom_attributes).to include('plan' => 'base', 'plan_modules' => [])
      expect(signed_up.limits).to include('agents' => 0, 'inboxes' => 0)
      expect(signed_up.trial_held_limits).to be_present
    end

    it 'offers an action on the card that is not switched off: it names the limits and is not waiting for another choice of modules' do
      signed_up.expire_trial!

      get card_path

      expect(plan_form['data-assigned']).to eq('true')
      expect(plan_form['data-limits-held']).to eq('true')
      expect(plan_form['data-initial-modules']).to eq('[]')
      expect(plan_button.text.squish).to eq('Вернуть лимиты и применить тариф')
      expect(plan_button['disabled']).to be_nil
      expect(plan_form.at_css('[data-plan-hint]').text.squish).to include('вернёт им прежние лимиты')
      expect(page.at_css('[data-testid="trial-limits-held"]').text.squish).to include('Нажмите «Вернуть лимиты и применить тариф» в блоке «Тариф»')
    end

    it 'keeps the usual «Применить» of an assigned plan while the trial runs, and after the limits are back' do
      get card_path
      expect(plan_form['data-limits-held']).to eq('false')
      expect(plan_button.text.squish).to eq('Применить')

      signed_up.expire_trial!
      post "#{card_path}/apply_plan"
      get card_path

      expect(plan_form['data-limits-held']).to eq('false')
      expect(plan_button.text.squish).to eq('Применить')
    end

    it 'shows in the preview, for the modules the clinic has now, that the limits come back', :aggregate_failures do
      signed_up.expire_trial!

      get "#{card_path}/plan_preview", params: { modules: [], fragment: 1 }

      preview = page.at_css('[data-testid="plan-preview"]')
      expect(preview['data-changed']).to eq('true')
      expect(preview.text.squish).to include('а операторам и каналам вернутся прежние лимиты')
      expect(preview.at_css('[data-preview="limits"]').text.squish).to include('Операторы: 0 → общее значение платформы', 'Каналы: 0 → общее значение платформы')
      expect(preview.at_css('[data-preview-note="trial_limits_restored"]')).to be_present
    end

    it 'gives the limits back, takes the zeros off, and leaves an entry in the audit log', :aggregate_failures do
      signed_up.expire_trial!

      expect { post "#{card_path}/apply_plan" }.to change { Audited::Audit.where(auditable_id: signed_up.id, action: 'apply_plan').count }.by(1)

      expect(signed_up.reload.limits.to_h.slice('agents', 'inboxes')).to be_empty
      expect(signed_up.trial_held_limits).to be_empty
      audit = Audited::Audit.where(auditable_id: signed_up.id, action: 'apply_plan').last
      expect(audit.audited_changes['limits']).to include('agents' => { 'from' => 0, 'to' => nil }, 'inboxes' => { 'from' => 0, 'to' => nil })
      expect(audit).to have_attributes(user_id: super_admin.id)
    end

    context 'when the clinic had limits of its own before the trial' do
      let(:limits_before_trial) { true }

      it 'gives back the numbers it had', :aggregate_failures do
        signed_up.expire_trial!
        expect(signed_up.reload.limits).to include('agents' => 0, 'inboxes' => 0)

        get "#{card_path}/plan_preview", params: { modules: [], fragment: 1 }
        expect(page.at_css('[data-preview="limits"]').text.squish).to include('Операторы: 0 → 5', 'Каналы: 0 → 3')

        post "#{card_path}/apply_plan"

        expect(signed_up.reload.limits).to include('agents' => 5, 'inboxes' => 3)
        audit = Audited::Audit.where(auditable_id: signed_up.id, action: 'apply_plan').last
        expect(audit.audited_changes['limits']).to include('agents' => { 'from' => 0, 'to' => 5 }, 'inboxes' => { 'from' => 0, 'to' => 3 })
      end
    end

    it 'does not offer it to a clinic whose trial kept the limits' do
      other = create(:account).tap { |record| record.disable_features!(*Featurable::FEATURE_NAMES) }
      Accounts::ApplyPlan.new(account: other, modules: []).call
      other.activate_trial!(3, keep_limits: true)
      other.expire_trial!

      get "/super_admin/accounts/#{other.id}"

      expect(plan_form['data-limits-held']).to eq('false')
      expect(plan_button.text.squish).to eq('Применить')
    end
  end

  describe 'POST /super_admin/accounts (creating a clinic)' do
    def create_clinic(name, extra = {})
      post '/super_admin/accounts', params: { account: { name: name, locale: 'ru', status: 'active' } }.merge(extra)
      Account.find_by!(name: name)
    end

    before { sign_in(super_admin, scope: :super_admin) }

    it 'applies the base right after the account is created' do
      created = create_clinic('Новый аккаунт')

      expect(response).to redirect_to(super_admin_account_path(created))
      expect(created.custom_attributes).to include('plan' => 'base', 'plan_modules' => [])
      expect(created.feature_enabled?('crm')).to be(true)
      expect(created.feature_enabled?('captain_scheduling_grounding_guard')).to be(false)
      expect(created.limits).to include('conversations' => ChatwootApp.max_limit)
    end

    it 'applies the modules of the optional modules param' do
      created = create_clinic('Аккаунт с модулями', modules: %w[quality])

      expect(created.custom_attributes['plan_modules']).to eq(%w[quality])
      expect(created.feature_enabled?('sla')).to be(true)
      expect(created.feature_enabled?('captain_integration')).to be(false)
    end

    it 'keeps the limits typed into the form' do
      created = create_clinic('Аккаунт с лимитами', account: { name: 'Аккаунт с лимитами', locale: 'ru', status: 'active', limits: { agents: '12' } })

      expect(created.limits).to include('agents' => 12, 'conversations' => ChatwootApp.max_limit)
    end

    it 'does not create the account when a module is unknown' do
      expect do
        post '/super_admin/accounts', params: { account: { name: 'Без модуля', locale: 'ru', status: 'active' }, modules: %w[ghost] }
      end.not_to change(Account, :count)

      expect(response).to redirect_to(new_super_admin_client_path)
      expect(flash[:alert]).to eq(flash_text(:plan_unknown_module))
    end

    it 'leaves the new account created and says so when the plan cannot be written' do
      allow_any_instance_of(Accounts::ApplyPlan).to receive(:call).and_raise(StandardError, 'boom') # rubocop:disable RSpec/AnyInstance

      created = create_clinic('Аккаунт без тарифа')

      expect(created).to be_persisted
      expect(created.custom_attributes).not_to have_key('plan')
      expect(flash[:alert]).to eq(flash_text(:plan_apply_failed))
    end
  end

  describe 'the plan filters of the account list' do
    let!(:based) { create(:account, name: 'Clinic with base') }
    let!(:with_module) { create(:account, name: 'Clinic with broadcasts') }
    let!(:without_plan) { create(:account, name: 'Clinic without plan') }

    before do
      Accounts::ApplyPlan.new(account: based, modules: []).call
      Accounts::ApplyPlan.new(account: with_module, modules: %w[broadcasts]).call
    end

    it 'replaces the tariff ladder with no plan, base and one filter per module' do
      keys = AccountDashboard::COLLECTION_FILTERS.keys

      expect(keys).to include(:no_plan, :plan_base, :module_ai_agents, :module_broadcasts, :module_quality, :module_extensions,
                              :trial_active, :trial_expired, :active, :suspended, :recent, :storage_high, :marked_for_deletion)
      expect(keys).not_to include(:starter, :growth, :advanced, :enterprise)
    end

    it 'has a Russian label for every plan filter' do
      filters = AccountDashboard::PLAN_FILTERS.keys

      expect(filters).to eq([:no_plan, :plan_base] + Accounts::Plans.module_keys.map { |key| :"module_#{key}" })
      filters.each do |filter|
        expect(I18n.t("super_admin.shell.filters.#{filter}", locale: :ru, raise: true)).to be_present
      end
    end

    it 'filters the accounts by plan and module' do
      filters = AccountDashboard::COLLECTION_FILTERS
      all = Account.all

      expect(filters[:no_plan].call(all)).to include(without_plan, account)
      expect(filters[:no_plan].call(all)).not_to include(based, with_module)
      expect(filters[:plan_base].call(all)).to contain_exactly(based, with_module)
      expect(filters[:module_broadcasts].call(all)).to contain_exactly(with_module)
      expect(filters[:module_ai_agents].call(all)).to be_empty
    end

    it 'works from the list page through the search prefix and shows Russian labels' do
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/accounts', params: { search: 'module_broadcasts:' }

      expect(response).to have_http_status(:success)
      expect(response.body).to include('Clinic with broadcasts')
      expect(response.body).not_to include('Clinic with base', 'Clinic without plan')
      expect(response.body).to include('Без тарифа', 'База', 'Модуль: ИИ-агенты')
      expect(response.body).not_to include('Тариф: Starter')
    end
  end

  describe 'the account form' do
    it 'no longer accepts plan_type: the old tariff field cannot make a zombie trial' do
      sign_in(super_admin, scope: :super_admin)

      patch "/super_admin/accounts/#{account.id}", params: {
        account: { name: account.name, locale: account.locale, status: account.status, plan_type: 'trial' }
      }

      expect(response).to have_http_status(:redirect)
      expect(account.reload.custom_attributes['plan_type']).to be_nil
      expect(account.custom_attributes).not_to have_key('trial_expires_at')
    end
  end
end
