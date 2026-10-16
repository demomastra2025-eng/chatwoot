require 'rails_helper'

# The lists, cards and forms of the users, AI bots, platform apps, banners, access tokens and system parameters are
# drawn by Administrate; this spec pins what the app turned into Russian there (names of roles and types, yes/no,
# titles of the «new» pages, the avatar and file fields).
RSpec.describe 'Super Admin lists and forms in Russian', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:page) { Nokogiri::HTML(response.body) }

  def title = page.at_css('main h1').text.squish

  def main_text = page.at_css('main').text.squish

  before do
    allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
    sign_in(super_admin, scope: :super_admin)
  end

  describe 'users' do
    it 'names the role of everyone in the list instead of the class name' do
      create(:user, name: 'Обычный пользователь')

      get '/super_admin/users'

      roles = page.css('td.cell-data--select').map { |cell| cell.text.squish }
      expect(roles).to contain_exactly('Пользователь', 'Супер-администратор')
      expect(main_text).not_to include('SuperAdmin')
    end

    it 'offers the role by name in the form, with a plain user as the first choice' do
      get '/super_admin/users/new'

      options = page.css('select#user_type option')
      expect(options.map { |option| [option.text, option['value']] }).to eq([['Пользователь', ''], ['Супер-администратор', 'SuperAdmin']])
      expect(title).to eq('Новый пользователь')
    end

    it 'shows the role and the two-factor state of a user in words' do
      user = create(:user)

      get "/super_admin/users/#{user.id}"

      expect(main_text).to include('Роль Пользователь', 'Двухфакторная аутентификация Выключена')
      expect(main_text).not_to include('MFA')
    end

    it 'sizes the avatar of a user and names the clinics of a membership in Russian' do
      account = create(:account, name: 'Клиника «Сезим»')
      user = create(:user, account: account)

      get "/super_admin/users/#{user.id}"

      expect(page.at_css('dd.attribute-data--avatar-field img')).to be_present
      expect(main_text).to include('Клиники и роли', 'Клиника «Сезим»')
    end

    it 'draws the file input as a button of its own, in Russian, with the name of the file next to it' do
      get '/super_admin/users/new'

      picker = page.at_css('.file-picker')
      expect(picker.at_css('input[type="file"].file-picker__input')).to be_present
      expect(picker.at_css('label.button').text.squish).to eq('Выбрать файл')
      expect(picker.at_css('[data-file-picker-name]').text.squish).to eq('Файл не выбран')
      expect(picker.at_css('label')['for']).to eq(picker.at_css('input')['id'])
    end

    it 'adds a user to a clinic with «клинику», not «аккаунт»' do
      user = create(:user)

      get "/super_admin/users/#{user.id}"

      expect(main_text).to include('Добавить в клинику')
      expect(main_text).not_to match(/Добавить в аккаунт/)
    end
  end

  describe 'AI bots' do
    it 'titles the new page «Новый AI-бот» and labels the clinic field' do
      get '/super_admin/agent_bots/new'

      expect(title).to eq('Новый AI-бот')
      expect(page.css('label').map { |label| label.text.squish }).to include('Клиника')
      expect(page.css('label').map { |label| label.text.squish }).not_to include('Account')
    end

    it 'names the bot in the title of its card' do
      bot = create(:agent_bot, name: 'Робот-регистратор')

      get "/super_admin/agent_bots/#{bot.id}"

      expect(title).to eq("AI-бот №#{bot.id} «Робот-регистратор»")
    end

    it 'has a line under the title and a button named after the bot' do
      get '/super_admin/agent_bots'

      expect(page.at_css('main .main-content__description').text).to include('Боты, которые отвечают клиентам')
      expect(page.at_css('main .main-content__actions a.button').text.squish).to eq('Новый AI-бот')
    end
  end

  describe 'platform apps' do
    it 'titles the new page and the card in Russian' do
      app = create(:platform_app, name: 'Мой портал')

      get '/super_admin/platform_apps/new'
      expect(title).to eq('Новое платформенное приложение')

      get "/super_admin/platform_apps/#{app.id}"
      expect(title).to eq("Приложение №#{app.id} «Мой портал»")
    end
  end

  describe 'banners' do
    it 'shows the type by name and «Да» or «Нет» for the switch, never true or false' do
      create(:platform_banner, banner_type: 'warning', active: true)
      create(:platform_banner, banner_type: 'info', active: false)

      get '/super_admin/platform_banners'

      expect(main_text).to include('Предупреждение', 'Информация', 'Да', 'Нет')
      expect(main_text).not_to match(/\b(true|false|warning|info)\b/)
    end

    it 'offers the types by name in the form' do
      get '/super_admin/platform_banners/new'

      expect(title).to eq('Новый баннер платформы')
      expect(page.css('select option').map { |option| option.text.squish }).to eq(%w[Информация Предупреждение Ошибка])
    end
  end

  describe 'access tokens' do
    it 'names the filters and the owners in Russian' do
      create(:user, name: 'Оператор Айгерим')

      get '/super_admin/access_tokens'

      expect(page.css('.segmented__item').map { |item| item.text.squish }).to eq(['Все', 'Пользователи', 'AI-боты', 'Платформенные приложения'])
      expect(main_text).to include('Оператор Айгерим')
      expect(main_text).not_to match(/User #\d+/)
    end
  end

  describe 'system parameters' do
    it 'names the button and the new page after the parameter, not after «Параметры системы»' do
      get '/super_admin/installation_configs'

      expect(page.at_css('main .main-content__actions a.button').text.squish).to eq('Новый параметр системы')

      get '/super_admin/installation_configs/new'

      expect(title).to eq('Новый параметр системы')
    end
  end

  describe 'users of a clinic' do
    it 'titles the new page «Добавить пользователя в клинику»' do
      get '/super_admin/account_users/new'

      expect(title).to eq('Добавить пользователя в клинику')
    end
  end
end
