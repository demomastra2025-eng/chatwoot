# frozen_string_literal: true

require 'rails_helper'

# The CSV of the account list: the same accounts the list shows (search box, filters, organization filter), the
# organization of each, and one entry of the audit log with who took the file and how many rows it holds.
RSpec.describe 'Super Admin accounts export', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:organization) { create(:organization, name: 'ТОО Север') }

  def rows
    CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
  end

  def page = Nokogiri::HTML(response.body)

  before { sign_in(super_admin, scope: :super_admin) }

  it 'has the organization of every account in its own column, «Без организации» for an account without one' do
    create(:account, name: 'Аккаунт Север', organization: organization)
    create(:account, name: 'Аккаунт Юг')

    get '/super_admin/accounts/export'

    expect(rows.headers).to eq(I18n.t('super_admin.accounts.csv.headers'))
    expect(rows.headers.third).to eq('Организация')
    by_name = rows.to_h { |row| [row['Название'], row['Организация']] }
    expect(by_name).to include('Аккаунт Север' => 'ТОО Север', 'Аккаунт Юг' => 'Без организации')
  end

  it 'stores an organization name that looks like a formula as plain text' do
    create(:account, name: 'Аккаунт Формула', organization: create(:organization, name: '=SUM(1+1)'))

    get '/super_admin/accounts/export'

    expect(rows.find { |row| row['Название'] == 'Аккаунт Формула' }['Организация']).to eq("'=SUM(1+1)")
  end

  describe 'the accounts it holds' do
    before do
      create(:account, name: 'Север Один', organization: organization)
      create(:account, name: 'Север Два')
      create(:account, name: 'Блокированный', status: :suspended, organization: organization)
    end

    it 'are all of them without a narrowing' do
      get '/super_admin/accounts/export'

      expect(rows.pluck('Название')).to include('Север Один', 'Север Два', 'Блокированный')
    end

    it 'are the ones the search box finds' do
      get '/super_admin/accounts/export', params: { search: 'север' }

      expect(rows.pluck('Название')).to contain_exactly('Север Один', 'Север Два')
    end

    it 'are the ones a filter of the list keeps' do
      get '/super_admin/accounts/export', params: { search: 'suspended:' }

      expect(rows.pluck('Название')).to eq(['Блокированный'])
    end

    it 'are the ones of the organization of the filter' do
      get '/super_admin/accounts/export', params: { organization_id: organization.id }

      expect(rows.pluck('Название')).to contain_exactly('Север Один', 'Блокированный')
    end

    it 'are the ones without an organization for «none»' do
      get '/super_admin/accounts/export', params: { organization_id: 'none' }

      expect(rows.pluck('Название')).to include('Север Два')
      expect(rows.pluck('Название')).not_to include('Север Один', 'Блокированный')
    end

    it 'combine the search and the organization' do
      get '/super_admin/accounts/export', params: { search: 'suspended:', organization_id: organization.id }

      expect(rows.pluck('Название')).to eq(['Блокированный'])
    end

    it 'ignore a filter value that is not an organization number' do
      get '/super_admin/accounts/export', params: { organization_id: "1' OR '1'='1" }

      expect(rows.pluck('Название')).to include('Север Один', 'Север Два', 'Блокированный')
    end
  end

  describe 'the list page' do
    it 'links to the file with the search and the organization of the list' do
      create(:account, name: 'Север Один', organization: organization)

      get '/super_admin/accounts', params: { search: 'север', organization_id: organization.id }

      href = page.css('a').find { |link| link['href'].to_s.start_with?('/super_admin/accounts/export') }['href']
      expect(Rack::Utils.parse_nested_query(URI(href).query)).to eq('search' => 'север', 'organization_id' => organization.id.to_s)
    end

    it 'links to the file of the whole list when nothing narrows it' do
      get '/super_admin/accounts'

      expect(page.css('a').pluck('href')).to include('/super_admin/accounts/export')
    end
  end

  describe 'the audit log' do
    def export_audits
      Audited::Audit.where(action: 'export_accounts')
    end

    it 'gets one entry with the super admin and the number of rows' do
      create(:account, name: 'Север Один')
      create(:account, name: 'Север Два')

      expect { get '/super_admin/accounts/export', params: { search: 'север' } }.to change(export_audits, :count).by(1)

      audit = export_audits.last
      expect(audit.user).to eq(super_admin)
      expect(audit.comment).to eq('super_admin')
      expect(audit.audited_changes).to eq('rows' => 2, 'search' => 'север')
    end

    it 'names the organization filter and counts the rows of an empty file as zero' do
      get '/super_admin/accounts/export', params: { organization_id: organization.id }

      expect(export_audits.last.audited_changes).to eq('rows' => 0, 'organization_id' => organization.id.to_s)
    end

    it 'does not keep the content of the rows' do
      create(:account, name: 'Секретное название аккаунта')

      get '/super_admin/accounts/export'

      expect(export_audits.last.audited_changes.to_s).not_to include('Секретное название аккаунта')
    end

    it 'is shown with its Russian name on the audit page' do
      get '/super_admin/accounts/export'

      get '/super_admin/audits'

      expect(response.body).to include('Выгрузка списка аккаунтов (CSV)')
    end
  end

  it 'asks a sign-in of someone who is not a super admin' do
    sign_out :super_admin

    expect { get '/super_admin/accounts/export' }.not_to change(Audited::Audit, :count)
    expect(response).to have_http_status(:redirect)
  end
end
