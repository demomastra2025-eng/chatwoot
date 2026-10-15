require 'rails_helper'

# Every time a person reads in the super admin is Astana time (UTC+5), never UTC. The moment below is
# 12:05:09 UTC, which is 17:05:09 in Astana.
RSpec.describe 'Super Admin times in Astana time', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:moment) { Time.utc(2026, 10, 15, 12, 5, 9) }
  let(:page) { Nokogiri::HTML(response.body) }

  before { sign_in(super_admin, scope: :super_admin) }

  it 'shows the time fields of a user page in Astana time' do
    user = create(:user, created_at: moment, confirmed_at: moment)

    get "/super_admin/users/#{user.id}"

    expect(response.body).to include('15.10.2026 17:05')
    expect(response.body).not_to include('15.10.2026 12:05')
  end

  it 'shows the time of an audit entry in Astana time' do
    account = create(:account)
    Audited::Audit.create!(
      auditable: account, associated: account, action: 'apply_plan', audited_changes: {}, comment: 'super_admin', created_at: moment
    )

    get '/super_admin/audits'

    expect(response.body).to include('15.10.2026 17:05:09')
    expect(response.body).not_to include('12:05:09')
  end

  it 'writes the creation time of a clinic in the export in Astana time' do
    account = create(:account)
    account.update_columns(created_at: moment) # rubocop:disable Rails/SkipsModelValidations

    get '/super_admin/accounts/export'

    rows = CSV.parse(response.body.delete_prefix("\u{FEFF}"), headers: true)
    row = rows.find { |candidate| candidate['ID'] == account.id.to_s }
    expect(row[I18n.t('super_admin.accounts.csv.headers').last]).to eq('15.10.2026 17:05')
  end

  describe 'the confirmation time of a user' do
    # the factory confirms the user right after creating it, so the moment is written afterwards
    let(:user) { create(:user).tap { |record| record.update_columns(confirmed_at: moment) } } # rubocop:disable Rails/SkipsModelValidations

    it 'is edited as Astana wall-clock time' do
      get "/super_admin/users/#{user.id}/edit"

      input = page.at_css('input[name="user[confirmed_at]"]')
      expect(input['value']).to eq('2026-10-15T17:05:09')
      expect(response.body).to include(I18n.t('super_admin.shell.astana_time_hint'))
    end

    it 'is saved back as the same moment' do
      patch "/super_admin/users/#{user.id}", params: { user: { confirmed_at: '2026-10-15T18:30' } }

      expect(user.reload.confirmed_at).to eq(Time.utc(2026, 10, 15, 13, 30))
    end

    it 'keeps a value that names its own zone' do
      patch "/super_admin/users/#{user.id}", params: { user: { confirmed_at: '2026-10-15T18:30:00Z' } }

      expect(user.reload.confirmed_at).to eq(Time.utc(2026, 10, 15, 18, 30))
    end
  end
end
