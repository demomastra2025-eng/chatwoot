require 'rails_helper'

# The organization seen from the account: the block of the card, the select of the edit form, the column and the filter
# of the account list. Every change of the organization of an account goes through SuperAdmin::OrganizationLinks, so the
# audit entries name the super admin and the generic «update» entry never repeats them.
RSpec.describe 'Super Admin account organizations', type: :request do
  let(:super_admin) { create(:super_admin) }

  # Not memoized: some examples open several pages in a row.
  def page = Nokogiri::HTML(response.body)

  def text(node) = node.text.squish

  def audits_of(record, action = nil)
    scope = Audited::Audit.where(auditable_type: record.class.name, auditable_id: record.id)
    action ? scope.where(action: action) : scope
  end

  def options_of(select)
    select.css('option').map { |option| [text(option), option['value']] }
  end

  def query_of(link)
    Rack::Utils.parse_nested_query(URI(link['href']).query)
  end

  # Counts the SQL statements a block runs (cached reads and schema lookups do not count)
  def query_count(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  describe 'for someone who is not a super admin' do
    it 'changes nothing' do
      organization = create(:organization)
      account = create(:account)

      post "/super_admin/accounts/#{account.id}/link_organization", params: { organization_id: organization.id }

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include('/super_admin/sign_in')
      expect(account.reload.organization).to be_nil
      expect(Audited::Audit.count).to eq(0)
    end
  end

  context 'when a super admin is signed in' do
    let!(:alatau) { create(:organization, :with_requisites, name: 'Алатау', bin: '980140000124') }
    let!(:nur) { create(:organization, name: 'Нур') }
    let(:account) { create(:account, name: 'Филиал 1') }

    before { sign_in(super_admin, scope: :super_admin) }

    describe 'the block of the card' do
      def block = page.at_css('[data-testid="organization-block"]')

      it 'says an account without an organization has none and offers the organizations by name' do
        get "/super_admin/accounts/#{account.id}"

        expect(response).to have_http_status(:ok)
        expect(text(block.at_css('h2'))).to eq('Организация')
        expect(text(block.at_css('[data-testid="account-organization"]'))).to eq('Аккаунт не привязан к организации.')
        select = block.at_css('select[name="organization_id"]')
        expect(options_of(select)).to eq([['Без организации', ''], ['Алатау · БИН 980140000124', alatau.id.to_s], ["Нур · ##{nur.id}", nur.id.to_s]])
        expect(select.at_css('option[selected]')['value']).to eq('')
        expect(response.body).not_to include('translation missing')
      end

      it 'does not ask before the first link' do
        get "/super_admin/accounts/#{account.id}"

        expect(block.at_css('input[type="submit"]')['data-confirm']).to be_nil
      end

      it 'shows the organization of the account with a link to its card and its БИН' do
        account.update_columns(organization_id: alatau.id) # rubocop:disable Rails/SkipsModelValidations

        get "/super_admin/accounts/#{account.id}"

        link = block.at_css('[data-testid="account-organization"] a')
        expect(link['href']).to eq("/super_admin/organizations/#{alatau.id}")
        expect(text(link)).to eq('Алатау')
        expect(text(block.at_css('[data-testid="account-organization"]'))).to include('БИН 980140000124')
        expect(block.at_css('select option[selected]')['value']).to eq(alatau.id.to_s)
      end

      it 'asks before an account that has an organization is moved or unlinked' do
        account.update_columns(organization_id: alatau.id) # rubocop:disable Rails/SkipsModelValidations

        get "/super_admin/accounts/#{account.id}"

        confirm = block.at_css('input[type="submit"]')['data-confirm']
        expect(confirm).to include('Сменить организацию аккаунта «Филиал 1»', 'Без организации', 'не изменятся')
      end

      it 'tells organizations of the same name apart' do
        twin = create(:organization, name: 'Алатау')

        get "/super_admin/accounts/#{account.id}"

        labels = block.css('select option').map { |option| text(option) }
        expect(labels).to include('Алатау · БИН 980140000124', "Алатау · ##{twin.id}")
      end

      it 'posts to the account' do
        get "/super_admin/accounts/#{account.id}"

        form = block.at_css('form')
        expect(form['action']).to eq("/super_admin/accounts/#{account.id}/link_organization")
        expect(form['method']).to eq('post')
      end
    end

    describe 'linking from the card' do
      def link(organization_id, target: account)
        post "/super_admin/accounts/#{target.id}/link_organization", params: { organization_id: organization_id }
      end

      it 'links the account and says so' do
        link(alatau.id)

        expect(response).to redirect_to("/super_admin/accounts/#{account.id}")
        expect(account.reload.organization).to eq(alatau)
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт привязан к организации «Алатау».')
        expect(text(page.at_css('[data-testid="account-organization"]'))).to include('Алатау')
      end

      it 'records it on both sides, signed by the super admin' do
        link(alatau.id)

        account_audit = audits_of(account, 'link_organization').sole
        expect(account_audit.user).to eq(super_admin)
        expect(account_audit.comment).to eq('super_admin')
        expect(account_audit.audited_changes).to eq('organization_id' => [nil, alatau.id], 'organization_name' => [nil, 'Алатау'])
        organization_audit = audits_of(alatau, 'link_account').sole
        expect(organization_audit.user).to eq(super_admin)
        expect(organization_audit.audited_changes).to eq('account_id' => account.id, 'account_name' => 'Филиал 1')
      end

      it 'writes nothing but the link: the plan, the limits and the channels of the account stay and no «update» entry appears' do
        Accounts::ApplyPlan.new(account: account, modules: %w[ai_agents]).call
        create(:inbox, account: account)
        before = account.reload.attributes.except('organization_id', 'updated_at')
        updates = audits_of(account, 'update').count

        link(alatau.id)

        expect(account.reload.attributes.except('organization_id', 'updated_at')).to eq(before)
        expect(audits_of(account, 'update').count).to eq(updates)
        expect(account.inboxes.count).to eq(1)
      end

      it 'moves the account to another organization and records all three entries' do
        link(alatau.id)
        Audited::Audit.delete_all

        link(nur.id)

        expect(account.reload.organization).to eq(nur)
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт перенесён в организацию «Нур».')
        expect(audits_of(account, 'link_organization').sole.audited_changes)
          .to eq('organization_id' => [alatau.id, nur.id], 'organization_name' => %w[Алатау Нур])
        expect(audits_of(alatau, 'unlink_account').sole.user).to eq(super_admin)
        expect(audits_of(nur, 'link_account').sole.user).to eq(super_admin)
      end

      it 'unlinks the account with «Без организации», keeps the account and says which organization it left' do
        link(alatau.id)
        Audited::Audit.delete_all

        link('')

        expect(account.reload.organization).to be_nil
        expect(Account.exists?(account.id)).to be(true)
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт отвязан от организации «Алатау».')
        account_audit = audits_of(account, 'unlink_organization').sole
        expect(account_audit.user).to eq(super_admin)
        expect(account_audit.audited_changes).to eq('organization_id' => [alatau.id, nil], 'organization_name' => ['Алатау', nil])
        expect(audits_of(alatau, 'unlink_account').sole.audited_changes).to eq('account_id' => account.id, 'account_name' => 'Филиал 1')
      end

      # Another super admin moves the account between the moment this request is read and the moment it is written
      def move_account_meanwhile(to)
        allow(SuperAdmin::OrganizationLinks).to receive(:new).and_wrap_original do |original, **options|
          account.update_columns(organization_id: to.id) # rubocop:disable Rails/SkipsModelValidations
          original.call(**options)
        end
      end

      it 'moves the account from the organization it holds now, and records that one as the organization it left' do
        link(alatau.id)
        Audited::Audit.delete_all
        third = create(:organization, name: 'Третья')
        move_account_meanwhile(third)

        link(nur.id)

        expect(account.reload.organization).to eq(nur)
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт перенесён в организацию «Нур».')
        expect(audits_of(account, 'link_organization').sole.audited_changes)
          .to eq('organization_id' => [third.id, nur.id], 'organization_name' => %w[Третья Нур])
        expect(audits_of(third, 'unlink_account').count).to eq(1)
        expect(audits_of(alatau, 'unlink_account')).to be_empty
        expect(audits_of(nur, 'link_account').count).to eq(1)
      end

      it 'says which organization «Без организации» took the account from when it was moved meanwhile' do
        link(alatau.id)
        Audited::Audit.delete_all
        move_account_meanwhile(nur)

        link('')

        expect(account.reload.organization).to be_nil
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт отвязан от организации «Нур».')
        expect(audits_of(account, 'unlink_organization').sole.audited_changes)
          .to eq('organization_id' => [nur.id, nil], 'organization_name' => ['Нур', nil])
        expect(audits_of(alatau, 'unlink_account')).to be_empty
      end

      it 'says nothing changed and records nothing when the account was moved meanwhile to the organization asked for' do
        link(alatau.id)
        Audited::Audit.delete_all
        move_account_meanwhile(nur)

        link(nur.id)

        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Организация аккаунта не изменилась.')
        expect(Audited::Audit.count).to eq(0)
      end

      it 'says nothing changed and records nothing when the account is already where it is asked to be' do
        link(alatau.id)
        Audited::Audit.delete_all

        link(alatau.id)
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Организация аккаунта не изменилась.')

        link('')
        link('')
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Организация аккаунта не изменилась.')
        expect(audits_of(account, 'link_organization').count).to eq(0)
        expect(Audited::Audit.where(action: %w[link_account unlink_account]).count).to eq(1)
      end

      it 'asks to choose an organization from the list and changes nothing for an unknown number, a list or nothing at all' do
        link(alatau.id)
        Audited::Audit.delete_all

        [0, 'abc', [1, 2], { id: 1 }].each do |wrong|
          link(wrong)
          expect(response).to redirect_to("/super_admin/accounts/#{account.id}")
          follow_redirect!
          expect(page.at_css('.flashes').text).to include('Выберите организацию из списка')
        end
        post "/super_admin/accounts/#{account.id}/link_organization"
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Выберите организацию из списка')

        expect(account.reload.organization).to eq(alatau)
        expect(Audited::Audit.count).to eq(0)
      end

      it 'links an account whose old data would not pass the validations of an account today' do
        account.update_columns(settings: { 'reporting_timezone' => 'Not/AZone' }) # rubocop:disable Rails/SkipsModelValidations

        link(alatau.id)

        expect(account.reload.organization).to eq(alatau)
      end

      it 'shows the account on the card of the organization' do
        link(alatau.id)

        get "/super_admin/organizations/#{alatau.id}"

        expect(page.css('[data-testid="accounts-block"] tbody tr[data-account-id]').pluck('data-account-id')).to eq([account.id.to_s])
      end
    end

    describe 'the edit form' do
      let(:account) { create(:account, name: 'Филиал 1', organization: alatau) }

      def select = page.at_css('select[name="account[organization_id]"]')

      it 'has a select «Организация» in the main section, with «Без организации» first and the current one chosen' do
        get "/super_admin/accounts/#{account.id}/edit"

        expect(response).to have_http_status(:ok)
        expect(text(page.at_css('label[for="account_organization_id"]'))).to eq('Организация')
        expect(options_of(select)).to eq([['Без организации', ''], ['Алатау · БИН 980140000124', alatau.id.to_s], ["Нур · ##{nur.id}", nur.id.to_s]])
        expect(select.at_css('option[selected]')['value']).to eq(alatau.id.to_s)
        expect(select.ancestors('fieldset').first.at_css('legend').text.squish).to eq('Основное')
        hints = page.css('.field-unit__hint').map { |hint| text(hint) }
        expect(hints).to include('Платящая сторона: реквизиты, БИН и договор. Тариф, лимиты и каналы остаются у аккаунта.')
        expect(response.body).not_to include('translation missing')
      end

      it 'has «Без организации» chosen for an account without one' do
        free = create(:account)

        get "/super_admin/accounts/#{free.id}/edit"

        expect(select.at_css('option[selected]')['value']).to eq('')
      end

      it 'is not on the form of a new account' do
        get '/super_admin/accounts/new'

        expect(response).to have_http_status(:ok)
        expect(page.at_css('select[name="account[organization_id]"]')).to be_nil
      end

      it 'is not a field the search box of the list looks into' do
        expect(AccountDashboard.new.search_attributes).not_to include(:organization_id)
      end

      it 'saves the new organization after the account and says both' do
        patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Филиал 1 (новый)', organization_id: nur.id } }

        expect(response).to redirect_to("/super_admin/accounts/#{account.id}")
        expect(account.reload).to have_attributes(name: 'Филиал 1 (новый)', organization: nur)
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт сохранён.', 'Аккаунт перенесён в организацию «Нур».')
      end

      it 'records the change through the links, signed by the super admin' do
        patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Филиал 1 (новый)', organization_id: nur.id } }

        link_entry = audits_of(account, 'link_organization').sole
        expect(link_entry.user).to eq(super_admin)
        expect(link_entry.comment).to eq('super_admin')
        expect(link_entry.audited_changes).to eq('organization_id' => [alatau.id, nur.id], 'organization_name' => %w[Алатау Нур])
        expect(audits_of(alatau, 'unlink_account').sole.user).to eq(super_admin)
        expect(audits_of(nur, 'link_account').sole.user).to eq(super_admin)
      end

      it 'does not repeat the organization in the generic «update» entry, which holds the other fields only' do
        patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Филиал 1 (новый)', organization_id: nur.id } }

        expect(audits_of(account, 'update').sole.audited_changes.keys).to eq(['name'])
      end

      it 'leaves no «update» entry at all when only the organization changes' do
        patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Филиал 1', organization_id: nur.id } }

        expect(account.reload.organization).to eq(nur)
        expect(audits_of(account, 'update')).to be_empty
        expect(audits_of(account, 'link_organization').count).to eq(1)
      end

      it 'links an account that had no organization' do
        free = create(:account, name: 'Свободный')

        patch "/super_admin/accounts/#{free.id}", params: { account: { name: 'Свободный', organization_id: alatau.id } }

        expect(free.reload.organization).to eq(alatau)
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт привязан к организации «Алатау».')
        expect(audits_of(free, 'link_organization').sole.audited_changes).to include('organization_id' => [nil, alatau.id])
      end

      it 'unlinks the account with «Без организации»' do
        patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Филиал 1', organization_id: '' } }

        expect(account.reload.organization).to be_nil
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт отвязан от организации «Алатау».')
        expect(audits_of(account, 'unlink_organization').sole.user).to eq(super_admin)
        expect(audits_of(alatau, 'unlink_account').sole.user).to eq(super_admin)
        expect(audits_of(account, 'update')).to be_empty
      end

      it 'records the organization the account really left when another super admin moved it while the form was open' do
        third = create(:organization, name: 'Третья')
        account
        allow(SuperAdmin::OrganizationLinks).to receive(:new).and_wrap_original do |original, **options|
          account.update_columns(organization_id: third.id) # rubocop:disable Rails/SkipsModelValidations
          original.call(**options)
        end

        patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Филиал 1 (новый)', organization_id: nur.id } }

        expect(account.reload).to have_attributes(name: 'Филиал 1 (новый)', organization: nur)
        expect(audits_of(account, 'link_organization').sole.audited_changes)
          .to eq('organization_id' => [third.id, nur.id], 'organization_name' => %w[Третья Нур])
        expect(audits_of(third, 'unlink_account').count).to eq(1)
        expect(audits_of(alatau, 'unlink_account')).to be_empty
      end

      it 'records and says nothing about the organization when the form sends the one it was drawn with' do
        patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Филиал 1 (новый)', organization_id: alatau.id } }

        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Аккаунт сохранён.')
        expect(page.at_css('.flashes').text).not_to include('организац')
        expect(Audited::Audit.where(action: %w[link_organization unlink_organization link_account unlink_account])).to be_empty
      end

      it 'keeps the organization when a request does not carry it' do
        patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Филиал 1 (новый)' } }

        expect(account.reload.organization).to eq(alatau)
        expect(Audited::Audit.where(action: %w[link_organization unlink_organization])).to be_empty
      end

      it 'keeps the organization when only the switches of the fine tuning are saved' do
        patch "/super_admin/accounts/#{account.id}", params: { enabled_features: { feature_sla: 'true' } }

        expect(account.reload.organization).to eq(alatau)
        expect(Audited::Audit.where(action: %w[link_organization unlink_organization])).to be_empty
      end

      it 'shows the form again with the picked organization and changes nothing when the account is invalid' do
        patch "/super_admin/accounts/#{account.id}", params: { account: { name: '', organization_id: nur.id } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(select.at_css('option[selected]')['value']).to eq(nur.id.to_s)
        expect(account.reload).to have_attributes(name: 'Филиал 1', organization: alatau)
        expect(Audited::Audit.where(action: %w[link_organization unlink_organization link_account unlink_account])).to be_empty
      end

      it 'saves the account and asks to choose an organization from the list when the number is unknown' do
        patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Филиал 1 (новый)', organization_id: '0' } }

        expect(account.reload).to have_attributes(name: 'Филиал 1 (новый)', organization: alatau)
        follow_redirect!
        expect(page.at_css('.flashes').text).to include('Выберите организацию из списка')
        expect(Audited::Audit.where(action: %w[link_organization unlink_organization])).to be_empty
      end

      it 'cannot give a new account an organization' do
        post '/super_admin/accounts', params: { account: { name: 'Новый', locale: 'ru', organization_id: alatau.id } }

        created = Account.find_by!(name: 'Новый')
        expect(created.organization).to be_nil
        expect(alatau.accounts.where(id: created.id)).to be_empty
      end
    end

    describe 'the account list' do
      let!(:in_alatau) { create(:account, name: 'Аккаунт Алатау', organization: alatau) }
      let!(:free) { create(:account, name: 'Аккаунт Свободный') }

      before { create(:account, name: 'Аккаунт Нур', organization: nur) }

      def names
        page.css('[data-testid="clinics-table"] tbody tr[data-account-id] td[data-bulk-cell] + td a').map { |link| text(link) }
      end

      def organization_cell(account)
        page.at_css("tr[data-account-id='#{account.id}']").css('td:not([data-bulk-cell])')[1]
      end

      describe 'the column' do
        it 'links the organization and shows a dash for an account without one' do
          get '/super_admin/accounts'

          link = organization_cell(in_alatau).at_css('a')
          expect(link['href']).to eq("/super_admin/organizations/#{alatau.id}")
          expect(text(link)).to eq('Алатау')
          expect(text(organization_cell(free))).to eq('—')
        end

        it 'does not change the other columns' do
          get '/super_admin/accounts'

          headers = page.css('[data-testid="clinics-table"] thead th').map { |header| text(header) }
          expect(headers).to eq(['', 'Аккаунт', 'Организация', 'Тариф', 'Операторы', 'Хранилище', 'Каналы', 'Статус', 'Действия'])
          expect(text(page.at_css("tr[data-account-id='#{free.id}']").css('td:not([data-bulk-cell])')[2])).to eq('Не назначен')
        end

        it 'costs the same number of queries for 2 and for 12 accounts with organizations' do
          get '/super_admin/accounts' # warms the caches the first request fills
          small = query_count { get '/super_admin/accounts' }
          expect(page.css('tr[data-account-id]').size).to eq(3)

          9.times { |index| create(:account, organization: create(:organization, name: "Орг #{index}")) }
          large = query_count { get '/super_admin/accounts' }

          expect(page.css('tr[data-account-id]').size).to eq(12)
          expect(large).to eq(small)
        end
      end

      describe 'the filter' do
        def filter_select = page.at_css('[data-testid="organization-filter"] select[name="organization_id"]')

        it 'is a select with all organizations, none and the organizations by name' do
          get '/super_admin/accounts'

          expect(options_of(filter_select)).to eq(
            [['Все организации', ''], ['Без организации', 'none'], ['Алатау · БИН 980140000124', alatau.id.to_s], ["Нур · ##{nur.id}", nur.id.to_s]]
          )
          expect(filter_select.at_css('option[selected]')['value']).to eq('')
          expect(text(page.at_css('[data-testid="organization-filter"] label'))).to eq('Организация')
          expect(page.at_css('[data-testid="organization-filter"] input[type="submit"]')['value']).to eq('Применить')
          expect(page.at_css('[data-testid="organization-filter"]')['method']).to eq('get')
        end

        it 'is not one of the segmented filters' do
          get '/super_admin/accounts', params: { organization_id: alatau.id }

          expect(page.css('.segmented .segmented__item').map { |item| text(item) }).not_to include('Организация')
        end

        it 'shows the accounts of the organization only, and keeps it chosen' do
          get '/super_admin/accounts', params: { organization_id: alatau.id }

          expect(names).to eq(['Аккаунт Алатау'])
          expect(filter_select.at_css('option[selected]')['value']).to eq(alatau.id.to_s)
        end

        it 'shows the accounts without an organization for «none»' do
          get '/super_admin/accounts', params: { organization_id: 'none' }

          expect(names).to eq(['Аккаунт Свободный'])
          expect(filter_select.at_css('option[selected]')['value']).to eq('none')
        end

        it 'shows everything for an empty value' do
          get '/super_admin/accounts', params: { organization_id: '' }

          expect(names).to contain_exactly('Аккаунт Алатау', 'Аккаунт Нур', 'Аккаунт Свободный')
        end

        it 'shows nothing, and says so, for an organization that does not exist' do
          get '/super_admin/accounts', params: { organization_id: '999999' }

          expect(names).to be_empty
          expect(response.body).to include('Ничего не найдено')
        end

        it 'asks for the whole list when the value is not a number, «none» or empty' do
          ['abc', '1; DROP TABLE accounts', '99999999999999999999999'].each do |wrong|
            get '/super_admin/accounts', params: { organization_id: wrong }

            expect(response).to have_http_status(:ok)
            expect(names).to contain_exactly('Аккаунт Алатау', 'Аккаунт Нур', 'Аккаунт Свободный')
          end

          get '/super_admin/accounts', params: { organization_id: [alatau.id] }
          expect(names).to contain_exactly('Аккаунт Алатау', 'Аккаунт Нур', 'Аккаунт Свободный')
        end

        it 'works with the search box' do
          create(:account, name: 'Другой филиал Алатау', organization: alatau)

          get '/super_admin/accounts', params: { organization_id: alatau.id, search: 'Алатау' }
          expect(names).to contain_exactly('Аккаунт Алатау', 'Другой филиал Алатау')

          get '/super_admin/accounts', params: { organization_id: alatau.id, search: 'Другой' }
          expect(names).to eq(['Другой филиал Алатау'])

          get '/super_admin/accounts', params: { organization_id: nur.id, search: 'Алатау' }
          expect(names).to be_empty
        end

        it 'works with the segmented filters' do
          in_alatau.update_columns(status: Account.statuses[:suspended]) # rubocop:disable Rails/SkipsModelValidations
          create(:account, name: 'Активный Алатау', organization: alatau)

          get '/super_admin/accounts', params: { organization_id: alatau.id, search: 'suspended:' }
          expect(names).to eq(['Аккаунт Алатау'])

          get '/super_admin/accounts', params: { organization_id: alatau.id, search: 'active:' }
          expect(names).to eq(['Активный Алатау'])

          get '/super_admin/accounts', params: { organization_id: 'none', search: 'active:' }
          expect(names).to eq(['Аккаунт Свободный'])
        end

        it 'is carried by the segmented filters, the sort link and the search box' do
          get '/super_admin/accounts', params: { organization_id: alatau.id, search: 'active:' }

          links = page.css('.segmented a.segmented__item')
          expect(links.map { |link| query_of(link)['organization_id'] }.uniq).to eq([alatau.id.to_s])
          expect(links.map { |link| query_of(link)['search'] }).to include(nil, 'trial_active:')
          sort = page.at_css('th a')
          expect(query_of(sort)).to include('organization_id' => alatau.id.to_s, 'account' => { 'order' => 'name', 'direction' => 'asc' })
          expect(page.at_css('form.search input[type="hidden"][name="organization_id"]')['value']).to eq(alatau.id.to_s)
        end

        it 'is kept by the link that clears the search' do
          get '/super_admin/accounts', params: { organization_id: nur.id, search: 'Нур' }

          clear = page.at_css('a.search__clear-link')
          expect(query_of(clear)).to eq('organization_id' => nur.id.to_s)
        end

        it 'sends the search term along with the organization' do
          get '/super_admin/accounts', params: { organization_id: nur.id, search: 'Нур' }

          expect(page.at_css('[data-testid="organization-filter"] input[type="hidden"][name="search"]')['value']).to eq('Нур')
        end

        it 'does not carry an organization nobody asked for' do
          get '/super_admin/accounts', params: { search: 'active:' }

          expect(page.css('.segmented a.segmented__item').map { |link| query_of(link) }).to all(satisfy { |query| !query.key?('organization_id') })
          expect(page.at_css('form.search input[name="organization_id"]')).to be_nil
        end

        it 'is kept by the pages of a long list' do
          create_list(:account, 21, organization: nur)

          get '/super_admin/accounts', params: { organization_id: nur.id }
          expect(page.css('tr[data-account-id]').size).to eq(20)
          expect(query_of(page.at_css('a[rel="next"]'))).to include('organization_id' => nur.id.to_s)

          get '/super_admin/accounts', params: { organization_id: nur.id, _page: 2 }
          expect(page.css('tr[data-account-id]').size).to eq(2)
        end

        it 'costs no more queries than the unfiltered list' do
          get '/super_admin/accounts'
          unfiltered = query_count { get '/super_admin/accounts' }
          filtered = query_count { get '/super_admin/accounts', params: { organization_id: alatau.id } }

          expect(filtered).to be <= unfiltered
        end
      end
    end
  end
end
