# frozen_string_literal: true

require 'rails_helper'

# The «Служебные» block of the clinic card (the owner decisions that differ from clinic to clinic), the check that
# refuses a switch the screens never offer, and the «Убрать из клиники» action of the users block.
RSpec.describe 'Super admin service flags and feature changes', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account, name: 'Клиника Алатау') }
  let(:card_path) { "/super_admin/accounts/#{account.id}" }
  let(:page) { Nokogiri::HTML(response.body) }

  before do
    Accounts::ApplyPlan.new(account: account, modules: []).call
    sign_in(super_admin, scope: :super_admin)
  end

  def text(node)
    node.text.squish
  end

  def service_block
    page.at_css('details#service-flags')
  end

  def audits(action)
    Audited::Audit.where(auditable_type: 'Account', auditable_id: account.id, action: action)
  end

  describe 'the «Служебные» block' do
    before { get card_path }

    it 'is a collapsed block after «Тонкая настройка» and before the users' do
      blocks = page.css('.admin-card-layout > div:first-child > *').filter_map { |node| node['data-testid'] }

      expect(service_block['open']).to be_nil
      expect(text(service_block.at_css('summary'))).to include('Служебные')
      expect(blocks.index('fine-tuning-block')).to be < blocks.index('service-flags-block')
      expect(blocks.index('service-flags-block')).to be < blocks.index('users-block')
    end

    it 'has a switch for each owner decision, named in Russian, with a line on what it does' do
      rows = service_block.css('[data-flag]')

      expect(rows.pluck('data-flag')).to eq(SuperAdmin::FineTuning::OWNER_DECISION_FLAGS)
      expect(text(rows.first)).to include('Один чат на пациента', 'Диалоги пациента из разных каналов собираются в один чат.')
      expect(text(service_block)).to include('Автораспределение, версия 2', 'Свой ключ OpenRouter у клиники')
    end

    it 'posts the switches like the fine tuning does: a hidden «false» before the checkbox, to the update of the clinic' do
      form = service_block.at_css('form')

      expect(form['action']).to eq(card_path)
      expect(form.at_css('input[name="_method"]')['value']).to eq('patch')
      SuperAdmin::FineTuning::OWNER_DECISION_FLAGS.each do |flag|
        name = "enabled_features[feature_#{flag}]"
        expect(form.at_css(%(input[type="hidden"][name="#{name}"]))['value']).to eq('false')
        expect(form.at_css(%(input[type="checkbox"][name="#{name}"]))['value']).to eq('true')
      end
      expect(form.css('[name^="account"]')).to be_empty
    end

    it 'asks a question that names the clinic before a switch is moved either way' do
      box = service_block.at_css('input#service-communication_threads')

      expect(box['data-confirm-on']).to include('Клиника Алатау', 'Один чат на пациента')
      expect(box['data-confirm-off']).to include('Клиника Алатау', 'Один чат на пациента')
      expect(response.body).to include('data-service-flags-form')
    end

    it 'shows the state of the clinic' do
      account.enable_features!('assignment_v2')
      get card_path

      expect(service_block.at_css('input#service-assignment_v2')['checked']).to be_present
      expect(service_block.at_css('input#service-communication_threads')['checked']).to be_nil
    end

    it 'no longer says that the developer switches these' do
      expect(text(page.at_css('details#fine-tuning'))).not_to include('разработчик')
      expect(response.body).not_to include('их включает разработчик по запросу')
    end

    it 'is left out of the plan switches of «Тонкая настройка»' do
      names = page.at_css('details#fine-tuning').css('input[type="checkbox"]').pluck('name')

      SuperAdmin::FineTuning::OWNER_DECISION_FLAGS.each do |flag|
        expect(names).not_to include("enabled_features[feature_#{flag}]")
      end
    end
  end

  describe 'saving the switches' do
    def save(states)
      patch card_path, params: { enabled_features: states.transform_keys { |flag| "feature_#{flag}" } }
    end

    it 'switches the decisions and says so' do
      save('communication_threads' => 'true', 'assignment_v2' => 'false', 'captain_openrouter_byok' => 'true')

      expect(response).to redirect_to(card_path)
      expect(flash[:notice]).to eq('Клиника сохранена.')
      account.reload
      expect(account.feature_enabled?('communication_threads')).to be(true)
      expect(account.feature_enabled?('captain_openrouter_byok')).to be(true)
      expect(account.feature_enabled?('assignment_v2')).to be(false)
    end

    it 'writes what changed to the audit log of the clinic, with the actor' do
      account.enable_features!('assignment_v2')

      save('communication_threads' => 'true', 'assignment_v2' => 'false', 'captain_openrouter_byok' => 'false')

      audit = audits('update_service_flags').sole
      expect(audit).to have_attributes(user_id: super_admin.id, comment: 'super_admin')
      expect(audit.remote_address).to be_present
      expect(audit.audited_changes['features']).to eq(
        'communication_threads' => { 'from' => false, 'to' => true },
        'assignment_v2' => { 'from' => true, 'to' => false }
      )
    end

    it 'writes nothing to the audit log when no decision moves' do
      save('communication_threads' => 'false', 'assignment_v2' => 'false', 'captain_openrouter_byok' => 'false')

      expect(response).to redirect_to(card_path)
      expect(audits('update_service_flags')).to be_empty
    end

    it 'does not audit the switches of «Тонкая настройка» as service flags' do
      patch card_path, params: { enabled_features: { feature_sla: 'true' } }

      expect(account.reload.feature_enabled?('sla')).to be(true)
      expect(audits('update_service_flags')).to be_empty
    end

    it 'is not touched by a plan: applying a plan keeps the decisions as they are' do
      account.enable_features!('communication_threads', 'captain_openrouter_byok')

      Accounts::ApplyPlan.new(account: account.reload, modules: %w[ai_agents quality]).call
      Accounts::ApplyPlan.new(account: account.reload, modules: []).call

      account.reload
      expect(account.feature_enabled?('communication_threads')).to be(true)
      expect(account.feature_enabled?('captain_openrouter_byok')).to be(true)
      expect(account.feature_enabled?('assignment_v2')).to be(false)
      expect(Accounts::Plans.managed_features & SuperAdmin::FineTuning::OWNER_DECISION_FLAGS).to be_empty
    end

    it 'shows in the audit log page with a Russian action name' do
      save('communication_threads' => 'true')

      get '/super_admin/audits'

      expect(response.body).to include('Изменение служебных настроек клиники')
    end
  end

  describe 'a change the screens never offer' do
    def rejected_page
      Nokogiri::HTML(response.body)
    end

    def alert_text
      text(rejected_page.at_css('.flash-alert'))
    end

    it 'refuses to switch on a function no plan enables, with 422 and a Russian message, and saves nothing of the request' do
      account.disable_features!('saml', 'sla')

      patch card_path, params: { enabled_features: { feature_saml: 'true', feature_sla: 'true' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(alert_text).to include('Изменения не сохранены.', 'Функцию «Единый вход SAML» нельзя включить: ни один тариф её не включает.')
      account.reload
      expect(account.feature_enabled?('saml')).to be(false)
      expect(account.feature_enabled?('sla')).to be(false)
    end

    it 'stays on the clinic card when the request came from the card, and says so from the edit form' do
      patch card_path, params: { enabled_features: { feature_saml: 'true' } }
      expect(rejected_page.at_css('[data-testid="plan-block"]')).to be_present

      patch card_path, params: { account: { name: 'Другое имя' }, enabled_features: { feature_saml: 'true' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(rejected_page.at_css(%(form[action="#{card_path}"] input[name="account[name]"]))).to be_present
      expect(account.reload.name).to eq('Клиника Алатау')
    end

    it 'refuses to switch off a function that must stay on' do
      account.enable_features!('agent_management')

      patch card_path, params: { enabled_features: { feature_agent_management: 'false' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(alert_text).to include('Функцию «Управление операторами» нельзя выключить')
      expect(account.reload.feature_enabled?('agent_management')).to be(true)
    end

    it 'refuses to change an internal function that is not an owner decision' do
      account.enable_features!('inbox_view')

      patch card_path, params: { enabled_features: { feature_inbox_view: 'false', feature_crm_v2: 'true' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(alert_text).to include('Функцию «Представление входящих» нельзя менять здесь')
      account.reload
      expect(account.feature_enabled?('inbox_view')).to be(true)
      expect(account.feature_enabled?('crm_v2')).to be(false)
    end

    it 'does not refuse a function no plan enables that the clinic already has: other fields still save' do
      account.enable_features!('scheduling_finance')

      patch card_path, params: { account: { name: 'Клиника Новая' }, enabled_features: { feature_scheduling_finance: 'true', feature_sla: 'true' } }

      expect(response).to redirect_to(card_path)
      account.reload
      expect(account.name).to eq('Клиника Новая')
      expect(account.feature_enabled?('scheduling_finance')).to be(true)
      expect(account.feature_enabled?('sla')).to be(true)
    end

    it 'lets a function no plan enables be switched off' do
      account.enable_features!('scheduling_finance')

      patch card_path, params: { enabled_features: { feature_scheduling_finance: 'false' } }

      expect(response).to redirect_to(card_path)
      expect(account.reload.feature_enabled?('scheduling_finance')).to be(false)
    end

    it 'refuses a new clinic that asks for a function no plan enables, and creates nothing' do
      expect do
        post '/super_admin/accounts', params: { account: { name: 'Новая клиника', locale: 'ru' }, enabled_features: { feature_saml: 'true' } }
      end.not_to change(Account, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(alert_text).to include('Единый вход SAML')
    end

    it 'leaves the owner decisions free' do
      patch card_path, params: { enabled_features: { feature_communication_threads: 'true' } }

      expect(response).to redirect_to(card_path)
      expect(account.reload.feature_enabled?('communication_threads')).to be(true)
    end

    it 'keeps the edit form working: it sends only the switches it shows' do
      get "#{card_path}/edit"
      names = Nokogiri::HTML(response.body).css('input[type="checkbox"][name^="enabled_features"]').pluck('name')
      params = names.to_h { |name| [name.delete_prefix('enabled_features[').delete_suffix(']'), account.feature_enabled?(name[/feature_(.*)\]/, 1]).to_s] }

      patch card_path, params: { account: { name: account.name, locale: account.locale, status: account.status }, enabled_features: params }

      expect(response).to redirect_to(card_path)
    end
  end

  describe 'the users block: «Убрать из клиники»' do
    let!(:member) { create(:user, account: account, role: :agent, name: 'Мерей') }
    let(:membership) { AccountUser.find_by!(account: account, user: member) }

    it 'offers it for each member, asking first' do
      get card_path

      form = page.at_css(%(form[action="/super_admin/account_users/#{membership.id}"]))
      expect(form.at_css('input[name="_method"]')['value']).to eq('delete')
      expect(text(form.at_css('button'))).to eq('Убрать из клиники')
      expect(form.at_css('button')['data-confirm']).to include('Мерей', 'Клиника Алатау', 'сам пользователь и его данные не удаляются')
    end

    it 'takes the member out of the clinic and keeps the user' do
      delete "/super_admin/account_users/#{membership.id}", headers: { 'HTTP_REFERER' => card_path }

      expect(response).to redirect_to(card_path)
      expect(flash[:notice]).to eq('Пользователь убран из клиники.')
      expect(AccountUser.where(id: membership.id)).to be_empty
      expect(User.exists?(member.id)).to be(true)
    end

    it 'writes it to the audit log of the clinic, with the actor, the user and the role' do
      delete "/super_admin/account_users/#{membership.id}"

      audit = audits('remove_user').sole
      expect(audit).to have_attributes(user_id: super_admin.id, comment: 'super_admin')
      expect(audit.audited_changes).to include('user_id' => member.id, 'email' => member.email, 'role' => 'agent')
    end

    it 'shows in the audit log page with a Russian action name' do
      delete "/super_admin/account_users/#{membership.id}"

      get '/super_admin/audits'

      expect(response.body).to include('Пользователь убран из клиники')
    end
  end
end
