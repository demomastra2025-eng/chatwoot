# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Super admin entries into an account', type: :request do
  let(:super_admin) { create(:super_admin, name: 'Айгерим Админ') }
  let!(:account) { create(:account, name: 'Клиника «Алатау»') }
  let!(:operator) { create(:user, name: 'Иван Петров', email: 'ivan@example.test', account: account, role: :administrator) }

  # Not memoized: some examples open several pages in a row.
  def page = Nokogiri::HTML(response.body)

  def history = page.at_css("[data-testid='impersonation-history']")

  before { sign_in(super_admin, scope: :super_admin) }

  describe 'the card of an account' do
    it 'has a collapsed block «Входы в аккаунт», empty until somebody has entered' do
      get "/super_admin/accounts/#{account.id}"

      expect(history.name).to eq('details')
      expect(history['open']).to be_nil
      expect(history.at_css('summary').text.squish).to start_with('Входы в аккаунт')
      expect(history['data-scope']).to eq('account')
      expect(history.at_css("[data-testid='impersonation-empty']").text).to eq('Входов пока не было.')
    end

    it 'lists the entry that «Войти в аккаунт» leaves: when, who, and as whom' do
      post "/super_admin/accounts/#{account.id}/impersonate"
      expect(response).to have_http_status(:redirect)

      get "/super_admin/accounts/#{account.id}"

      row = history.at_css("[data-testid='impersonation-entry']")
      cells = row.css('td').map { |cell| cell.text.squish }
      expect(cells[0]).to match(/\A\d\d\.\d\d\.\d{4} \d\d:\d\d:\d\d\z/)
      expect(cells[1]).to eq('Айгерим Админ')
      expect(cells[2]).to eq('Иван Петров · ivan@example.test')
      expect(row.at_css('a')['href']).to eq("/super_admin/users/#{operator.id}")
    end

    it 'shows only the entries into this account' do
      other = create(:account, name: 'Сезим')
      other_operator = create(:user, account: other, role: :administrator, email: 'maria@example.test')
      SuperAdmin::AccountAudit.record(account: other, actor: super_admin, action: 'impersonate',
                                      changes: { 'impersonated_user_id' => other_operator.id, 'impersonated_email' => other_operator.email })

      get "/super_admin/accounts/#{account.id}"

      expect(history.text).not_to include('maria@example.test')
      expect(history.at_css("[data-testid='impersonation-empty']")).to be_present
    end

    it 'shows at most the last twenty' do
      25.times do
        SuperAdmin::AccountAudit.record(account: account, actor: super_admin, action: 'impersonate',
                                        changes: { 'impersonated_user_id' => operator.id, 'impersonated_email' => operator.email })
      end

      get "/super_admin/accounts/#{account.id}"

      expect(history.css("[data-testid='impersonation-entry']").size).to eq(20)
    end
  end

  describe 'the card of a user' do
    it 'has the block too, with the account that was entered' do
      post "/super_admin/accounts/#{account.id}/impersonate", params: { user_id: operator.id }

      get "/super_admin/users/#{operator.id}"

      expect(history['data-scope']).to eq('user')
      expect(history['open']).to be_nil
      row = history.at_css("[data-testid='impersonation-entry']")
      expect(row.css('td').map { |cell| cell.text.squish }[1..]).to eq(['Айгерим Админ', "Клиника «Алатау» ##{account.id}"])
      expect(row.at_css('a')['href']).to eq("/super_admin/accounts/#{account.id}")
    end

    it 'is empty for a user nobody has entered as' do
      get "/super_admin/users/#{operator.id}"

      expect(history.at_css("[data-testid='impersonation-empty']")).to be_present
    end

    it 'is on the card of a super admin as well' do
      get "/super_admin/users/#{super_admin.id}"

      expect(response).to have_http_status(:success)
      expect(history).to be_present
    end
  end
end
