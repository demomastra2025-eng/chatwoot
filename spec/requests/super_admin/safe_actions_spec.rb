require 'rails_helper'

# The dangerous one-click buttons of the super admin ask «точно?» in one way (a panel: the question, what will happen, the
# fields the action needs, «Да» and «Отмена»), and what they do is written to the audit log: the reset of the counters, taking a
# person out of an account, every delete, the token of a partner.
RSpec.describe 'Super Admin safe actions', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account, name: 'Аккаунт Алатау') }
  let(:card_path) { "/super_admin/accounts/#{account.id}" }

  before { sign_in(super_admin, scope: :super_admin) }

  def page = Nokogiri::HTML(response.body)

  def text(node) = node.text.squish

  def panel(key) = page.at_css("[data-testid='confirm-#{key}']")

  # The question the panel asks, what it says will happen, the answer and the way out
  def title(node) = text(node.at_css('.admin-ask__title'))

  def answer(node) = text(node.at_css('button[type="submit"]'))

  describe 'the panel itself' do
    before { get card_path }

    it 'opens from a button, asks the question and names what will happen, with the line about the audit log' do
      node = panel('reset-responses')

      expect(node.name).to eq('details')
      expect(text(node.at_css('summary'))).to eq('Сбросить ответы ИИ')
      expect(title(node)).to eq('Обнулить ответы ИИ?')
      expect(text(node.at_css('.admin-ask__panel'))).to include('Счётчик станет 0', 'Действие запишется в журнал аудита')
    end

    it 'does the action by a normal form, only after the answer «Да», and has «Отмена»' do
      node = panel('reset-responses')

      form = node.at_css('form')
      expect(form['action']).to eq("#{card_path}/reset_captain_responses_usage")
      expect(form['method']).to eq('post')
      expect(form['data-single-submit']).to be_present
      expect(answer(node)).to eq('Да, обнулить')
      expect(text(node.at_css('[data-confirm-close]'))).to eq('Отмена')
      expect(node.at_css('[data-confirm-close]')['type']).to eq('button')
    end

    it 'opening the panel does nothing: looking at the card changes no counter' do
      account.update!(custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 12))

      get card_path

      expect(account.reload.custom_attributes['captain_responses_usage']).to eq(12)
      expect(Audited::Audit.where(action: 'reset_captain_responses_usage')).to be_empty
    end

    it 'leaves no browser pop-up question on the buttons of the card' do
      expect(page.css('[data-confirm]')).to be_empty
    end
  end

  describe 'the counters that count by themselves' do
    def last_audit(action) = Audited::Audit.where(action: action).order(:id).last

    it 'shows the number the counter holds in the question, with its thousands separated' do
      account.update!(custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 1240, 'captain_tokens_usage' => 55_000))

      get card_path

      expect(text(panel('reset-responses').at_css('.admin-ask__panel'))).to include('Сейчас учтено ответов: 1 240')
      expect(text(panel('reset-tokens').at_css('.admin-ask__panel'))).to include('Сейчас учтено токенов: 55 000')
    end

    it 'sets the answers of the AI to zero, says what the number was and writes the audit entry' do
      account.update!(custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 1240))

      post "#{card_path}/reset_captain_responses_usage"

      expect(response).to redirect_to(card_path)
      expect(flash[:notice]).to eq('Ответы ИИ обнулены: было 1 240, теперь 0.')
      expect(account.reload.custom_attributes['captain_responses_usage']).to eq(0)
      audit = last_audit('reset_captain_responses_usage')
      expect(audit).to have_attributes(auditable_id: account.id, associated_id: account.id, user_id: super_admin.id, comment: 'super_admin')
      expect(audit.audited_changes).to eq('before' => 1240, 'after' => 0)
    end

    it 'does the same for the tokens' do
      account.update!(custom_attributes: account.custom_attributes.merge('captain_tokens_usage' => 800))

      post "#{card_path}/reset_captain_tokens_usage"

      expect(flash[:notice]).to eq('Токены ИИ обнулены: было 800, теперь 0.')
      expect(account.reload.custom_attributes['captain_tokens_usage']).to eq(0)
      expect(last_audit('reset_captain_tokens_usage').audited_changes).to eq('before' => 800, 'after' => 0)
    end

    it 'does the same for the e-mails of today' do
      3.times { account.increment_email_sent_count }

      post "#{card_path}/reset_email_usage"

      expect(flash[:notice]).to eq('Счётчик писем обнулён: было 3, теперь 0.')
      expect(account.emails_sent_today).to eq(0)
      expect(last_audit('reset_email_usage').audited_changes).to eq('before' => 3, 'after' => 0)
    end

    it 'says so, and writes no entry, when the counter could not be reset' do
      allow_any_instance_of(Account).to receive(:save).and_return(false) # rubocop:disable RSpec/AnyInstance

      post "#{card_path}/reset_captain_tokens_usage"

      expect(flash[:alert]).to eq('Не удалось сбросить расход токенов ИИ.')
      expect(Audited::Audit.where(action: 'reset_captain_tokens_usage')).to be_empty
    end

    it 'shows when and by whom the counter was last reset, and that it never was' do
      get card_path
      expect(text(page.at_css('[data-counter="responses"] [data-testid="last-reset"]'))).to eq('Ещё ни разу не сбрасывали')

      post "#{card_path}/reset_captain_responses_usage"
      get card_path

      line = text(page.at_css('[data-counter="responses"] [data-testid="last-reset"]'))
      expect(line).to start_with('Последний сброс: ')
      expect(line).to include(SuperAdmin::DisplayHelper.format_time(last_audit('reset_captain_responses_usage').created_at), super_admin.name)
      expect(text(page.at_css('[data-counter="tokens"] [data-testid="last-reset"]'))).to eq('Ещё ни разу не сбрасывали')
    end

    it 'does not touch the counter of another account' do
      other = create(:account)
      other.update!(custom_attributes: other.custom_attributes.merge('captain_responses_usage' => 7))

      post "#{card_path}/reset_captain_responses_usage"

      expect(other.reload.custom_attributes['captain_responses_usage']).to eq(7)
    end
  end

  describe 'taking a person out of an account' do
    let!(:administrator) { create(:user, name: 'Айгуль Админ', account: account, role: :administrator) }
    let!(:agent) { create(:user, name: 'Мерей Оператор', account: account, role: :agent) }

    def membership_of(user) = AccountUser.find_by(account: account, user: user)

    it 'asks on the card of the account, names the person and the account, and says that the person stays' do
      get card_path

      node = panel("remove-user-#{agent.id}")
      expect(title(node)).to eq('Убрать Мерей Оператор из аккаунта «Аккаунт Алатау»?')
      expect(text(node.at_css('.admin-ask__panel'))).to include('Сам пользователь и его данные не удаляются', 'журнал аудита')
      expect(node.at_css('form')['action']).to eq("/super_admin/account_users/#{membership_of(agent).id}")
      expect(node.at_css('form input[name="_method"]')['value']).to eq('delete')
      expect(answer(node)).to eq('Да, убрать')
    end

    it 'warns when the person is the only administrator of the account, and only then' do
      get card_path

      warning = text(panel("remove-user-#{administrator.id}").at_css('.admin-ask__warning'))
      expect(warning).to include('единственный администратор', 'Аккаунт Алатау')
      expect(panel("remove-user-#{agent.id}").at_css('.admin-ask__warning')).to be_nil

      create(:user, account: account, role: :administrator)
      get card_path

      expect(panel("remove-user-#{administrator.id}").at_css('.admin-ask__warning')).to be_nil
    end

    it 'takes only the membership away and writes the entry to the audit log of the account' do
      expect { delete "/super_admin/account_users/#{membership_of(agent).id}" }.to change(AccountUser, :count).by(-1)

      expect(User.find_by(id: agent.id)).to be_present
      audit = Audited::Audit.where(action: 'remove_user').last
      expect(audit).to have_attributes(auditable_id: account.id, user_id: super_admin.id)
      expect(audit.audited_changes).to include('user_id' => agent.id, 'email' => agent.email, 'role' => 'agent')
    end

    it 'asks the same way on the card of the user, in the list of the accounts of the person' do
      get "/super_admin/users/#{agent.id}"

      node = panel("delete-account_user-#{membership_of(agent).id}")
      expect(title(node)).to eq('Убрать Мерей Оператор из аккаунта «Аккаунт Алатау»?')
      expect(node.at_css('form')['action']).to eq("/super_admin/account_users/#{membership_of(agent).id}")
      expect(page.css('[data-confirm]')).to be_empty
    end

    it 'warns on the card of the user as well when the person is the only administrator' do
      get "/super_admin/users/#{administrator.id}"

      warning = text(panel("delete-account_user-#{membership_of(administrator).id}").at_css('.admin-ask__warning'))
      expect(warning).to include('единственный администратор')
    end
  end

  describe 'deleting a user from the list' do
    let!(:person) { create(:user, name: 'Иван Петров') }

    before do
      create(:account_user, account: account, user: person, role: :administrator)
      create(:account_user, account: create(:account, name: 'Второй'), user: person, role: :agent)
    end

    it 'asks with the name, the number of accounts and the accounts the person leaves without an administrator' do
      get '/super_admin/users'

      node = panel("delete-user-#{person.id}")
      expect(title(node)).to eq('Удалить пользователя «Иван Петров»?')
      expect(text(node.at_css('.admin-ask__panel'))).to include('Аккаунтов у него: 2', 'вернуть его нельзя')
      expect(text(node.at_css('.admin-ask__warning'))).to include('«Аккаунт Алатау»')
      expect(node.at_css('form input[name="_method"]')['value']).to eq('delete')
      expect(page.css('[data-confirm]')).to be_empty
    end

    it 'says it in the singular for one account and in the plural for several' do
      get '/super_admin/users'
      warning = text(panel("delete-user-#{person.id}").at_css('.admin-ask__warning'))
      expect(warning).to eq('Он единственный администратор в аккаунте «Аккаунт Алатау»: он останется без администратора.')

      AccountUser.find_by(user_id: person.id, account: Account.find_by(name: 'Второй')).update!(role: :administrator)
      get '/super_admin/users'

      warning = text(panel("delete-user-#{person.id}").at_css('.admin-ask__warning'))
      expect(warning).to start_with('Он единственный администратор в аккаунтах')
      expect(warning).to match(/«(Аккаунт Алатау» и «Второй|Второй» и «Аккаунт Алатау)»: они останутся без администратора/)
    end

    it 'reads the accounts of the whole page at once, not once per person' do
      create_list(:user, 4).each { |user| create(:account_user, account: account, user: user) }
      allow(SuperAdmin::UserRemovalNotes).to receive(:for).and_call_original

      get '/super_admin/users'

      expect(SuperAdmin::UserRemovalNotes).to have_received(:for).once
    end

    it 'deletes the person after the answer, and the delete is in the audit log' do
      expect { delete "/super_admin/users/#{person.id}" }.to change(User, :count).by(-1)

      audit = Audited::Audit.where(auditable_type: 'User', auditable_id: person.id, action: 'destroy').last
      expect(audit).to have_attributes(user_id: super_admin.id)
    end
  end

  describe 'the partner access' do
    let!(:partner) { create(:platform_app, name: 'Партнёр Альфа') }

    it 'asks before the token is reissued, and says that the old one stops working at once' do
      get "/super_admin/platform_apps/#{partner.id}"

      node = panel('reissue-token')
      expect(text(node.at_css('summary'))).to eq('Перевыпустить токен')
      expect(text(node.at_css('.admin-ask__panel'))).to include('Старый токен перестанет работать сразу', 'Партнёр Альфа')
      expect(node.at_css('form')['action']).to eq("/super_admin/platform_apps/#{partner.id}/reissue_token")
      expect(answer(node)).to eq('Да, перевыпустить')
    end

    it 'asks before the access is deleted, on its card and in the list' do
      get "/super_admin/platform_apps/#{partner.id}"
      expect(text(panel('delete-partner').at_css('.admin-ask__panel'))).to include('Его токен перестанет работать', 'Партнёр Альфа')
      expect(page.css('[data-confirm]')).to be_empty

      get '/super_admin/platform_apps'
      node = panel("delete-platform_app-#{partner.id}")
      expect(title(node)).to eq('Удалить партнёрский доступ «Партнёр Альфа»?')
      expect(page.css('[data-confirm]')).to be_empty
    end

    it 'writes the reissue and the delete to the audit log' do
      post "/super_admin/platform_apps/#{partner.id}/reissue_token"
      delete "/super_admin/platform_apps/#{partner.id}"

      expect(Audited::Audit.where(auditable_type: 'PlatformApp', auditable_id: partner.id).pluck(:action)).to include('reissue_token', 'destroy')
    end
  end

  describe 'the organization' do
    let!(:organization) { create(:organization, name: 'Сеть Альфа') }

    it 'asks before it is deleted, with the name and the audit line' do
      get "/super_admin/organizations/#{organization.id}"

      node = panel('delete-organization')
      expect(text(node.at_css('.admin-ask__panel'))).to include('Сеть Альфа', 'удалить нельзя', 'журнал аудита')
      expect(node.at_css('form')['action']).to eq("/super_admin/organizations/#{organization.id}")
      expect(page.css('[data-confirm]')).to be_empty
    end

    it 'asks before an account is unlinked' do
      create(:account, name: 'Филиал 1').tap { |branch| branch.update!(organization: organization) }

      get "/super_admin/organizations/#{organization.id}"

      node = page.at_css("[data-testid='confirm-unlink-#{Account.find_by(name: 'Филиал 1').id}']")
      expect(text(node.at_css('.admin-ask__panel'))).to include('Филиал 1', 'Сеть Альфа')
      expect(page.css('[data-confirm]')).to be_empty
    end
  end

  describe 'the trial and the other buttons of the card' do
    it 'asks about the trial, the cache and the plan in the same way' do
      Accounts::ApplyPlan.new(account: account, modules: []).call
      account.activate_trial!(3, keep_limits: true)
      account.enable_features!('sla')

      get card_path

      expect(text(panel('extend-trial').at_css('.admin-ask__panel'))).to include('Продлить пробный период на')
      expect(text(panel('expire-trial').at_css('.admin-ask__panel'))).to include('Завершить пробный период сейчас?')
      expect(text(panel('reset-cache').at_css('.admin-ask__panel'))).to include('Сбросить кэш интерфейса аккаунта?')
      expect(text(panel('reset-plan').at_css('.admin-ask__panel'))).to include('Вернуть функции аккаунта к тарифу?')
      expect(page.css('[data-confirm]')).to be_empty
    end

    it 'asks before a deletion that was scheduled is taken back' do
      account.update!(custom_attributes: { 'marked_for_deletion_at' => 3.days.from_now.iso8601 })

      get card_path

      expect(text(panel('cancel-deletion').at_css('.admin-ask__panel'))).to include('Отменить удаление аккаунта «Аккаунт Алатау»?')
    end
  end

  describe 'the picture of a user' do
    let!(:person) { create(:user, :with_avatar, name: 'Иван Петров') }

    it 'asks inside the form of the user, with a link the Rails script sends as DELETE (no form can be nested), and no pop-up' do
      get "/super_admin/users/#{person.id}/edit"

      node = page.at_css("[data-testid^='confirm-remove-file-']")
      expect(text(node.at_css('.admin-ask__title'))).to start_with('Удалить файл')
      expect(text(node.at_css('.admin-ask__panel'))).to include('вернуть его нельзя', 'журнал аудита')
      expect(node.at_css('form')).to be_nil
      link = node.at_css('a[data-method="delete"]')
      expect(link['href']).to start_with("/super_admin/users/#{person.id}/avatar")
      expect(text(link)).to eq('Да, удалить файл')
      expect(page.css('[data-confirm]')).to be_empty
    end

    it 'removes the picture after the answer and writes it to the audit log' do
      attachment_id = person.avatar.attachment.id

      delete "/super_admin/users/#{person.id}/avatar", params: { attachment_id: attachment_id }

      expect(person.reload.avatar).not_to be_attached
      audit = Audited::Audit.where(auditable_type: 'User', auditable_id: person.id, action: 'delete_avatar').last
      expect(audit).to have_attributes(user_id: super_admin.id)
    end
  end

  describe 'the push subscriptions' do
    let!(:person) { create(:user, email: 'operator@example.test', name: 'Operator User') }

    it 'asks inside the form of the table, and the delete is written to the audit log' do
      subscription = create(:notification_subscription, :fcm, user: person, identifier: 'operator-device')

      get '/super_admin/push_diagnostics', params: { user_query: person.email }

      node = panel('delete-subscriptions')
      expect(text(node.at_css('.admin-ask__panel'))).to include('Удалить выбранные подписки?')
      expect(node.at_css('form')).to be_nil
      expect(node.at_css('button[type="submit"]')['formaction']).to eq('/super_admin/push_diagnostics/destroy_subscriptions')
      expect(page.css('[data-confirm]')).to be_empty

      post '/super_admin/push_diagnostics/destroy_subscriptions', params: { user_id: person.id, subscription_ids: [subscription.id] }

      audit = Audited::Audit.where(action: 'delete_push_subscriptions').last
      expect(audit).to have_attributes(auditable_id: person.id, user_id: super_admin.id)
      expect(audit.audited_changes).to include('deleted' => 1, 'subscription_ids' => [subscription.id])
    end
  end
end
