require 'rails_helper'

# The cards of an account, a user and an organization keep in view what the owner reads, and fold what only a developer reads
# (numbers, dates of the last change, tokens, service attributes) under «Для разработчика», collapsed.
RSpec.describe 'Super admin cards: «Для разработчика»', type: :request do
  let(:super_admin) { create(:super_admin) }

  before { sign_in(super_admin, scope: :super_admin) }

  # The page of the last response (read again after every request of the example)
  def page = Nokogiri::HTML(response.body)

  def text(node)
    node.text.squish
  end

  def developer_block
    page.at_css('[data-testid="developer-block"], [data-testid="technical-block"]')
  end

  def facts
    developer_block.css('[data-testid="developer-facts"] .admin-kv__row').to_h { |row| [text(row.at_css('dt')), text(row.at_css('dd'))] }
  end

  describe 'the card of an account' do
    let(:account) { create(:account, name: 'Аккаунт Алатау', locale: 'ru', custom_attributes: { 'industry' => 'clinic' }) }

    before { Accounts::ApplyPlan.new(account: account, modules: []).call }

    it 'has one collapsed block «Для разработчика», the last of the main column, with the number, the language code and the version of the plan' do
      get "/super_admin/accounts/#{account.id}"

      block = page.at_css('[data-testid="technical-block"]')
      expect(block.name).to eq('details')
      expect(block['open']).to be_nil
      expect(text(block.at_css('summary'))).to include('Для разработчика', 'Служебные данные аккаунта')
      expect(facts).to include('Номер' => account.id.to_s, 'Код языка' => 'ru', 'Версия тарифа' => Accounts::Plans.version.to_s)
      expect(facts['Изменено']).to eq(SuperAdmin::DisplayHelper.format_time(account.reload.updated_at))
      expect(page.css('[data-testid="technical-block"]').size).to eq(1)
    end

    it 'keeps the service attributes and the users the limit does not count in the same block' do
      get "/super_admin/accounts/#{account.id}"

      block = page.at_css('[data-testid="technical-block"]')
      expect(block.at_css('[data-attribute="industry"]')).to be_present
      expect(block.at_css('[data-testid="excluded-ids"]')).to be_present
    end

    it 'does not print the version of the plan, a number of a technical kind, outside the block' do
      get "/super_admin/accounts/#{account.id}"

      expect(text(page.at_css('[data-testid="info-block"]'))).not_to include('версия')
      expect(text(page.at_css('[data-testid="info-block"]'))).to include('Язык', 'русский')
    end

    it 'says the language an account has in words, the one it has when it is not Russian' do
      account.update!(locale: 'en')
      get "/super_admin/accounts/#{account.id}"

      expect(text(page.at_css('[data-testid="info-block"]'))).to include('английский')
    end
  end

  describe 'the card of a user' do
    let(:user) { create(:user, name: 'Иван Петров') }

    before { create(:account_user, user: user, account: create(:account), role: :administrator) }

    it 'keeps the name, the role, the e-mail, the dates of registration and confirmation, the accounts and the two-factor state in view' do
      get "/super_admin/users/#{user.id}"

      view = page.css('section.admin-card').map { |card| text(card) }.join(' ')
      expect(response).to have_http_status(:ok)
      expect(view).to include('Иван Петров', user.email, 'Зарегистрирован', 'Аккаунты и роли', 'Двухфакторная аутентификация')
      expect(page.css('section.admin-card dt.attribute-label').map { |label| label['id'] }).not_to include('id', 'updated_at', 'access_token')
    end

    it 'folds the number, the date of the last change and the token under «Для разработчика», collapsed' do
      get "/super_admin/users/#{user.id}"

      block = page.at_css('[data-testid="developer-block"]')
      expect(block.name).to eq('details')
      expect(block['open']).to be_nil
      expect(text(block.at_css('summary'))).to include('Для разработчика', 'Служебные данные пользователя')
      expect(block.css('.admin-collapse__body > dl > dt').map { |label| label['id'] }).to eq(%w[id updated_at access_token])
      expect(text(block.at_css('.admin-collapse__body > dl > dd'))).to eq(user.id.to_s)
    end

    it 'does not draw the empty row of the e-mail that is waiting for confirmation, and draws it when there is one' do
      get "/super_admin/users/#{user.id}"
      expect(page.at_css('dt#unconfirmed_email')).to be_nil

      user.update!(unconfirmed_email: 'new-address@example.test')
      get "/super_admin/users/#{user.id}"
      expect(text(page.at_css('dt#unconfirmed_email').next_element)).to eq('new-address@example.test')
    end

    it 'never prints the whole token: only its last characters, and only under the block' do
      token = user.access_token.token
      get "/super_admin/users/#{user.id}"

      expect(token).to be_present
      expect(response.body).not_to include(token)
      expect(page.css('section.admin-card dt#access_token')).to be_empty
      expect(page.css('[data-testid="developer-block"] dt#access_token').size).to eq(1)
    end
  end

  describe 'the card of an organization' do
    let(:organization) { create(:organization, :with_requisites, name: 'Алатау Медикал') }

    it 'keeps the number out of the header and puts it, with the dates, into a collapsed «Для разработчика»' do
      get "/super_admin/organizations/#{organization.id}"

      expect(text(page.at_css('[data-testid="organization-meta"]'))).not_to include("##{organization.id}")
      block = page.at_css('[data-testid="technical-block"]')
      expect(block.name).to eq('details')
      expect(block['open']).to be_nil
      expect(text(block.at_css('summary'))).to include('Для разработчика', 'Служебные данные организации')
      expect(facts).to include('Номер' => organization.id.to_s)
      expect(facts['Создано']).to eq(SuperAdmin::DisplayHelper.format_time(organization.created_at))
    end

    it 'keeps the requisites and the contract in view' do
      get "/super_admin/organizations/#{organization.id}"

      expect(page.at_css('[data-testid="requisites-block"]')).to be_present
      expect(page.at_css('[data-testid="contract-block"]')).to be_present
    end
  end
end
