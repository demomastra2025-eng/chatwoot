# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Super admin actions on many accounts', type: :request do
  let(:super_admin) { create(:super_admin) }
  let!(:first) { create(:account, name: 'Клиника «Алатау»', status: 'active') }
  let!(:second) { create(:account, name: 'Сезим', status: 'active') }
  let!(:blocked) { create(:account, name: 'Заблокированный', status: 'suspended') }

  # Not memoized: some examples open several pages in a row.
  def page = Nokogiri::HTML(response.body)

  def bulk_path = '/super_admin/account_bulk_actions'

  # The numbers of accounts (a number that is not an account of the platform may stand for one)
  def ids(*accounts) = accounts.map { |account| account.respond_to?(:id) ? account.id : account }

  def audits(account, action) = Audited::Audit.where(auditable_type: 'Account', auditable_id: account.id, action: action)

  def bare(account) = account.tap { |record| record.disable_features!(*Featurable::FEATURE_NAMES) }

  describe 'the list' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'has a tick for each account that belongs to the form of the bar, and one in the header that ticks the page' do
      get '/super_admin/accounts'

      boxes = page.css('tbody input[type="checkbox"][name="account_ids[]"]')
      expect(boxes.pluck('value')).to match_array(ids(first, second, blocked).map(&:to_s))
      expect(boxes.map { |box| box['form'] }.uniq).to eq(['bulk-accounts-form'])
      expect(boxes.first['aria-label']).to start_with('Выбрать аккаунт «')
      header = page.at_css('thead input[type="checkbox"]')
      expect(header['title']).to eq('Выбрать все на странице')
      expect(header['name']).to be_nil
    end

    it 'has an action bar with the five actions that opens the confirmation page' do
      get '/super_admin/accounts'

      form = page.at_css('form#bulk-accounts-form')
      expect(form['action']).to eq("#{bulk_path}/new")
      expect(form['method']).to eq('get')
      buttons = form.css('button[type="submit"][name="bulk_action"]')
      expect(buttons.pluck('value')).to eq(%w[apply_plan extend_trial suspend activate link_organization])
      expect(buttons.map { |button| button.text.squish }).to eq(
        ['Применить тариф и модули', 'Продлить пробный период', 'Заблокировать', 'Разблокировать', 'Привязать к организации']
      )
    end

    it 'counts the ticked accounts, offers «Выбрать все на странице» and says how many can be chosen' do
      get '/super_admin/accounts'

      expect(page.at_css('form#bulk-accounts-form').text).to include('Выбрано: 0', 'Выбрать все на странице', 'Снять выбор')
      expect(page.at_css("[data-testid='bulk-bar']").text).to include('не больше 200 аккаунтов')
    end

    it 'sends the list the operator is on along, so the way back keeps the search and the page' do
      get '/super_admin/accounts', params: { search: 'сезим' }

      expect(page.at_css('form#bulk-accounts-form input[name="back"]')['value']).to eq("/super_admin/accounts?search=#{CGI.escape('сезим')}")
    end

    it 'keeps a click on a tick from opening the account' do
      get '/super_admin/accounts'

      expect(page.at_css('tbody td[data-bulk-cell] input[type="checkbox"]')).to be_present
      expect(response.body).to include('event.stopPropagation()')
    end

    it 'has a row for an empty list that spans the new column' do
      Account.delete_all

      get '/super_admin/accounts'

      expect(page.at_css('tbody td[colspan]')['colspan']).to eq('9')
    end
  end

  describe 'access' do
    it 'sends an unauthenticated visitor to the login and changes nothing' do
      post bulk_path, params: { bulk_action: 'suspend', account_ids: ids(first) }

      expect(response).to redirect_to('/super_admin/sign_in')
      expect(first.reload).to be_active
    end

    it 'does not let a clinic administrator in' do
      sign_in(create(:user, account: first, role: :administrator))

      post bulk_path, params: { bulk_action: 'suspend', account_ids: ids(first) }
      get "#{bulk_path}/new", params: { bulk_action: 'suspend', account_ids: ids(first) }

      expect(response).to have_http_status(:redirect)
      expect(first.reload).to be_active
      expect(response.body).not_to include('Клиника «Алатау»')
    end
  end

  describe 'GET /super_admin/account_bulk_actions/new' do
    before { sign_in(super_admin, scope: :super_admin) }

    def confirm(action, accounts, **extra)
      get "#{bulk_path}/new", params: { bulk_action: action, account_ids: ids(*accounts) }.merge(extra)
    end

    it 'says how many accounts there are, how many change and what is skipped and why' do
      confirm('suspend', [first, second, blocked])

      expect(response).to have_http_status(:success)
      expect(page.at_css('main h1').text.squish).to eq('Заблокировать')
      expect(page.at_css('main .main-content__description').text.squish).to start_with('Выбрано аккаунтов: 3')
      stats = page.css("[data-testid='stat']").map { |stat| stat.text.squish }
      expect(stats).to eq(['Изменятся 2 аккаунта', 'Будет пропущен 1 уже заблокирован — 1'])
      expect(page.at_css("[data-testid='bulk-warning']").text).to include('Заблокированный аккаунт не обслуживает операторов')
    end

    it 'gives the counts the form of the noun: one account, two accounts, five accounts' do
      stats = -> { page.css("[data-testid='stat']").map { |stat| stat.text.squish } }

      confirm('suspend', [first, blocked])
      expect(stats.call).to eq(['Изменится 1 аккаунт', 'Будет пропущен 1 уже заблокирован — 1'])

      confirm('suspend', [first, second])
      expect(stats.call.first).to eq('Изменятся 2 аккаунта')

      confirm('suspend', [first, second, *create_list(:account, 3)])
      expect(stats.call.first).to eq('Изменятся 5 аккаунтов')
    end

    it 'shows a line for each account: how it is now and what happens to it' do
      confirm('suspend', [first, second, blocked])

      rows = page.css("[data-testid='bulk-entries'] tbody tr")
      expect(rows.map { |row| [row['data-account-id'].to_i, row['data-outcome']] }).to eq(
        [[first.id, 'change'], [second.id, 'change'], [blocked.id, 'skip']]
      )
      expect(rows.first.css('td').map { |cell| cell.text.squish }).to eq(["Клиника «Алатау» ##{first.id}", 'Активен', 'Изменится Заблокирован'])
      expect(rows.last['data-reason']).to eq('already_suspended')
    end

    it 'writes nothing by looking' do
      confirm('suspend', [first, second])

      expect(first.reload).to be_active
      expect(audits(first, 'suspend_account')).to be_empty
    end

    it 'puts the number of accounts in the right Russian form on the button' do
      confirm('suspend', [first])
      expect(page.at_css("[data-testid='bulk-submit']")['value']).to eq('Применить к 1 аккаунту')

      confirm('suspend', [first, second])
      expect(page.at_css("[data-testid='bulk-submit']")['value']).to eq('Применить к 2 аккаунтам')
    end

    it 'carries the action, the accounts and the way back to the button that runs it' do
      confirm('suspend', [first, second], back: '/super_admin/accounts?search=a')

      form = page.at_css("form[action='#{bulk_path}']")
      expect(form['method']).to eq('post')
      expect(form.at_css('input[name="bulk_action"]')['value']).to eq('suspend')
      expect(form.css('input[name="account_ids[]"]').pluck('value')).to eq(ids(first, second).map(&:to_s))
      expect(form.at_css('input[name="back"]')['value']).to eq('/super_admin/accounts?search=a')
      expect(page.css('a.button').find { |link| link.text.squish == 'Отмена' }['href']).to eq('/super_admin/accounts?search=a')
    end

    it 'has no button when nothing would change' do
      confirm('suspend', [blocked])

      expect(page.at_css("[data-testid='bulk-submit']")).to be_nil
      expect(page.at_css("[data-testid='bulk-confirm']").text).to include('Менять нечего')
    end

    it 'does not follow a way back that leaves the list of accounts' do
      confirm('suspend', [first], back: 'https://evil.example/super_admin/accounts')

      expect(page.at_css('input[name="back"]')['value']).to eq('/super_admin/accounts')
    end

    it 'names a deleted account and an account marked for deletion as skipped' do
      SuperAdmin::AccountDeletion.new(account: second, actor: super_admin).schedule

      confirm('suspend', [first, second, 987_654_321])

      reasons = page.css("[data-testid='bulk-entries'] tbody tr").pluck('data-reason')
      expect(reasons).to eq(['', 'deleting', 'missing'])
    end

    context 'when the action is the trial' do
      it 'shows the new end of the trial and skips an account without one' do
        first.activate_trial!(7, keep_limits: true)

        confirm('extend_trial', [first, second])

        rows = page.css("[data-testid='bulk-entries'] tbody tr")
        expect(rows.first.css('td').map { |cell| cell.text.squish }[1]).to match(/\AДо \d\d\.\d\d\.\d{4} \d\d:\d\d\z/)
        expect(rows.first.css('td').last.text.squish).to match(/\AИзменится До \d\d\.\d\d\.\d{4} \d\d:\d\d\z/)
        expect(rows.last['data-reason']).to eq('not_trial')
        expect(rows.last.css('td').last.text.squish).to eq('Пропустим Нет пробного периода из админ-панели')
      end
    end

    context 'when the action is the plan' do
      before { [first, second].each { |account| bare(account) } }

      it 'asks for the modules first and shows no changes until they are chosen' do
        confirm('apply_plan', [first, second])

        expect(page.at_css("[data-testid='bulk-setting']")).to be_present
        expect(page.css("input[name='modules[]']").pluck('value')).to eq(%w[ai_agents broadcasts quality extensions])
        expect(page.at_css("[data-testid='bulk-entries']")).to be_nil
        expect(page.at_css("[data-testid='bulk-submit']")).to be_nil
        expect(page.at_css("[data-testid='bulk-setting'] input[name='chosen']")['value']).to eq('1')
        expect(page.at_css("[data-testid='bulk-setting'] input[type='submit']")['value']).to eq('Показать, что изменится')
      end

      it 'summarises the preview of the plan for every account once the modules are chosen' do
        confirm('apply_plan', [first, second, blocked], chosen: '1', modules: %w[ai_agents])

        expect(page.at_css("[data-testid='bulk-setting']")).to be_present
        expect(page.at_css("[data-bulk-functions='enable']").text).to match(/— \d+/)
        expect(page.css("input[name='modules[]'][checked]").pluck('value')).to eq(%w[ai_agents])
        rows = page.css("[data-testid='bulk-entries'] tbody tr")
        expect(rows.first.css('td').last.text.squish).to match(/\AИзменится База \+ ИИ-агенты Включится: \d+/)
        expect(page.at_css("[data-testid='bulk-submit']")['value']).to eq('Применить к 3 аккаунтам')
      end

      it 'carries the chosen modules to the button that runs the plan, and writes nothing by looking' do
        confirm('apply_plan', [first, second], chosen: '1', modules: %w[ai_agents])

        confirm_form = page.at_css("[data-testid='bulk-confirm'] form")
        expect(confirm_form.css('input[name="modules[]"]').pluck('value')).to eq(%w[ai_agents])
        expect(confirm_form.at_css('input[name="chosen"]')['value']).to eq('1')
        expect(audits(first, 'apply_plan')).to be_empty
        expect(first.reload.custom_attributes).not_to have_key('plan')
      end

      it 'tells an account that is on a trial about it once, with how many' do
        first.activate_trial!(7, keep_limits: true)

        confirm('apply_plan', [first, second], chosen: '1', modules: %w[ai_agents])

        note = page.at_css("[data-bulk-note='trial_active']")
        expect(note.text).to include('Аккаунтов с отметкой — 1')
      end

      it 'refuses a module that does not exist' do
        confirm('apply_plan', [first], chosen: '1', modules: %w[ghost])

        expect(page.at_css("[data-testid='bulk-error']").text).to eq('Такого модуля нет. Выберите модули из списка.')
        expect(page.at_css("[data-testid='bulk-entries']")).to be_nil
      end
    end

    context 'when the action is the organization' do
      let!(:organization) { create(:organization, :with_requisites, name: 'Алатау Медикал') }

      it 'asks for the organization first, with «Без организации» among the choices' do
        confirm('link_organization', [first, second])

        select = page.at_css("[data-testid='bulk-setting'] select#organization_id")
        expect(select.css('option').map { |option| [option.text.squish, option['value']] }).to eq(
          [['Выберите организацию', ''], ['Без организации', 'none'], ["Алатау Медикал · БИН #{organization.bin}", organization.id.to_s]]
        )
        expect(page.at_css("[data-testid='bulk-entries']")).to be_nil
      end

      it 'previews where the accounts go once the organization is chosen' do
        second.update!(organization: organization)

        confirm('link_organization', [first, second], chosen: '1', organization_id: organization.id.to_s)

        rows = page.css("[data-testid='bulk-entries'] tbody tr")
        expect(rows.first.css('td').map { |cell| cell.text.squish }[1..]).to eq(['Без организации', 'Изменится Алатау Медикал'])
        expect(rows.last['data-reason']).to eq('already_there')
        expect(page.at_css("[data-testid='bulk-confirm'] input[name='organization_id']")['value']).to eq(organization.id.to_s)
      end

      it 'does not take a form without the choice for «Без организации»' do
        confirm('link_organization', [first], chosen: '1', organization_id: '')

        expect(page.at_css("[data-testid='bulk-error']").text).to eq('Выберите организацию из списка или «Без организации».')
        expect(page.at_css("[data-testid='bulk-entries']")).to be_nil
      end
    end

    context 'when the request is wrong' do
      it 'sends back to the list with a word about it' do
        confirm('delete_everything', [first])
        expect(response).to redirect_to('/super_admin/accounts')
        expect(flash[:alert]).to eq('Такого действия нет. Выберите действие на панели над списком.')

        get "#{bulk_path}/new", params: { bulk_action: 'suspend' }
        expect(flash[:alert]).to eq('Отметьте в списке хотя бы один аккаунт.')

        get "#{bulk_path}/new", params: { bulk_action: 'suspend', account_ids: { '0' => first.id } }
        expect(flash[:alert]).to eq('Список аккаунтов передан в неверном виде. Отметьте аккаунты в списке заново.')
      end

      it 'refuses more than 200 accounts' do
        get "#{bulk_path}/new", params: { bulk_action: 'suspend', account_ids: (1..201).to_a }

        expect(response).to redirect_to('/super_admin/accounts')
        expect(flash[:alert]).to eq('За один раз можно выбрать не больше 200 аккаунтов. Ничего не изменено.')
      end

      it 'shows the confirmation of exactly 200' do
        get "#{bulk_path}/new", params: { bulk_action: 'suspend', account_ids: ids(first) + (900_000_000...900_000_199).to_a }

        expect(response).to have_http_status(:success)
        expect(page.css("[data-testid='bulk-entries'] tbody tr").size).to eq(200)
      end
    end
  end

  describe 'POST /super_admin/account_bulk_actions' do
    before { sign_in(super_admin, scope: :super_admin) }

    def run(action, accounts, **extra)
      post bulk_path, params: { bulk_action: action, account_ids: ids(*accounts) }.merge(extra)
    end

    it 'blocks the accounts, goes back to the list and sums up in Russian: done, skipped and why' do
      run('suspend', [first, second, blocked], back: '/super_admin/accounts?search=a')

      expect(response).to redirect_to('/super_admin/accounts?search=a')
      expect(flash[:notice]).to eq('Заблокировать: успешно 2, пропущено 1 (уже заблокирован — 1).')
      expect([first, second, blocked].map { |account| account.reload.status }).to eq(%w[suspended suspended suspended])
    end

    it 'leaves one entry of the audit log for each account it changed, and none for the others' do
      run('suspend', [first, second, blocked])

      [first, second].each do |account|
        entries = Audited::Audit.where(auditable_type: 'Account', auditable_id: account.id, action: 'suspend_account')
        expect(entries.count).to eq(1)
        expect(entries.first).to have_attributes(user_id: super_admin.id, comment: 'super_admin', audited_changes: include('bulk' => true))
        expect(entries.first.remote_address).to be_present
      end
      expect(Audited::Audit.where(auditable_id: blocked.id, action: 'suspend_account')).to be_empty
    end

    it 'unblocks' do
      run('activate', [blocked, first])

      expect(blocked.reload).to be_active
      expect(flash[:notice]).to eq('Разблокировать: успешно 1, пропущено 1 (не заблокирован — 1).')
    end

    it 'applies the plan and the modules' do
      [first, second].each { |account| bare(account) }

      run('apply_plan', [first, second], chosen: '1', modules: %w[ai_agents broadcasts])

      expect(flash[:notice]).to eq('Применить тариф и модули: успешно 2, пропущено 0.')
      [first, second].each do |account|
        expect(account.reload.custom_attributes).to include('plan' => 'base', 'plan_modules' => %w[ai_agents broadcasts])
        expect(audits(account, 'apply_plan').count).to eq(1)
      end
    end

    it 'does not apply the plan to a request that did not choose the modules' do
      bare(first)

      run('apply_plan', [first])

      expect(flash[:alert]).to eq('Сначала выберите параметры действия и посмотрите, что изменится. Ничего не изменено.')
      expect(first.reload.custom_attributes).not_to have_key('plan')
    end

    it 'does not unlink anybody from a request that did not choose the organization' do
      organization = create(:organization)
      first.update!(organization: organization)

      run('link_organization', [first], chosen: '1')

      expect(flash[:alert]).to start_with('Сначала выберите параметры')
      expect(first.reload.organization_id).to eq(organization.id)
    end

    it 'links the accounts to the organization' do
      organization = create(:organization, :with_requisites, name: 'Алатау Медикал')

      run('link_organization', [first, second], chosen: '1', organization_id: organization.id.to_s)

      expect(flash[:notice]).to eq('Привязать к организации: успешно 2, пропущено 0.')
      expect([first, second].map { |account| account.reload.organization_id }).to eq([organization.id] * 2)
      expect(audits(first, 'link_organization').count).to eq(1)
    end

    it 'extends the trial of the accounts that have one' do
      first.activate_trial!(7, keep_limits: true)
      expires_before = first.trial_expires_at

      run('extend_trial', [first, second])

      expect(flash[:notice]).to eq('Продлить пробный период: успешно 1, пропущено 1 (нет пробного периода из админ-панели — 1).')
      expect(first.reload.trial_expires_at).to be > expires_before
      expect(audits(first, 'extend_trial').count).to eq(1)
    end

    it 'is a warning, not a success, when nothing was changed' do
      run('suspend', [blocked])

      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to eq('Заблокировать: успешно 0, пропущено 1 (уже заблокирован — 1).')
    end

    it 'is a warning that counts the accounts it had no time for, and leaves them untouched' do
      stub_const('SuperAdmin::BulkAccounts::TIME_BUDGET', -1)

      run('suspend', [first, second])

      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to eq('Заблокировать: успешно 0, пропущено 2 (не хватило времени, аккаунт не тронут — 2).')
      expect([first.reload, second.reload]).to all(be_active)
    end

    it 'refuses more than 200 accounts whole, and changes none' do
      post bulk_path, params: { bulk_action: 'suspend', account_ids: ids(first, second) + (900_000_000...900_000_199).to_a }

      expect(flash[:alert]).to eq('За один раз можно выбрать не больше 200 аккаунтов. Ничего не изменено.')
      expect(first.reload).to be_active
      expect(second.reload).to be_active
      expect(Audited::Audit.where(action: 'suspend_account')).to be_empty
    end

    it 'accepts exactly 200 and counts the numbers that are not accounts as skipped' do
      post bulk_path, params: { bulk_action: 'suspend', account_ids: ids(first, second) + (900_000_000...900_000_198).to_a }

      expect(flash[:notice]).to eq('Заблокировать: успешно 2, пропущено 198 (аккаунт не найден — 198).')
      expect(first.reload).to be_suspended
    end

    it 'does not follow a way back that is not the list of accounts' do
      run('suspend', [first], back: 'https://evil.example/')
      expect(response).to redirect_to('/super_admin/accounts')

      run('activate', [first], back: '//evil.example/super_admin/accounts')
      expect(response).to redirect_to('/super_admin/accounts')

      run('suspend', [first], back: '/super_admin/users')
      expect(response).to redirect_to('/super_admin/accounts')
    end

    it 'keeps the filters and the page of the list on the way back' do
      run('suspend', [first], back: '/super_admin/accounts?search=active%3A&organization_id=none&_page=2')

      expect(response).to redirect_to('/super_admin/accounts?_page=2&organization_id=none&search=active%3A')
    end

    it 'goes back to the plain list when the way back cannot be read' do
      run('activate', [first], back: '/super_admin/accounts?search=%E0%A4%A')

      expect(response).to redirect_to('/super_admin/accounts')
    end

    it 'puts the summary on the list the next page shows' do
      run('suspend', [first])
      follow_redirect!

      expect(page.at_css('.flash-notice').text.squish).to eq('Заблокировать: успешно 1, пропущено 0.')
    end
  end
end
