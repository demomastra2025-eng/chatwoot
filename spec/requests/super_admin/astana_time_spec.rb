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

  describe 'the OpenRouter diagnostics of the AI config page' do
    let(:diagnostics) do
      {
        key_status: { health: { checked_at: '2026-10-15T12:05:09Z', key: {} } },
        catalog: { last_refreshed_at: '2026-10-15T12:05:09Z', last_started_at: '2026-10-15T12:00:00Z' },
        runtime: { last_event_at: '2026-10-15T12:05:09Z' }
      }
    end

    before do
      allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')
      allow(Llm::OpenRouterDiagnostics).to receive(:call).and_return(diagnostics)
    end

    it 'shows every moment in Astana time, not as an ISO string in UTC' do
      get '/super_admin/app_config?config=captain'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('15.10.2026 17:05', 'Запуск: 15.10.2026 17:00')
      expect(response.body).not_to include('2026-10-15T12:05:09Z')
    end

    it 'says «никогда» and «неизвестно» in Russian when there is nothing to show' do
      allow(Llm::OpenRouterDiagnostics).to receive(:call).and_return({})

      get '/super_admin/app_config?config=captain'

      section = Nokogiri::HTML(response.body).at_css('#openrouter-diagnostics').text.squish
      expect(section).to include('Проверен: никогда', 'неизвестно')
      expect(section).not_to match(/\bnever\b|\bunknown\b|\bnot_checked\b|\bmissing\b/)
    end
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

  # The datetime input of a form shows Astana wall-clock time, so whatever controller serves the form must turn it back
  # into a moment: the base controller does it for the attributes of any dashboard.
  describe 'every form that edits a date and time' do
    def dashboard_classes
      Dir[Rails.root.join('{app,enterprise/app}/dashboards/*_dashboard.rb')].map { |path| File.basename(path, '.rb').camelize.constantize }
    end

    def time_field?(type)
      field_class = type.respond_to?(:deferred_class) ? type.deferred_class : type
      field_class.is_a?(Class) && field_class <= Administrate::Field::DateTime
    end

    def time_form_attributes(dashboard)
      names = %w[new create edit update].flat_map do |action|
        form = dashboard.form_attributes(action)
        form.is_a?(Hash) ? form.values.flatten : Array(form)
      end
      names.uniq.select { |name| time_field?(dashboard.attribute_types[name]) }
    end

    def resource_params_owners(controller)
      owners = []
      method = controller.instance_method(:resource_params)
      while method
        owners << method.owner
        method = method.super_method
      end
      owners
    end

    it 'is served by a controller whose resource_params reaches the conversion of the base controller' do
      edited = dashboard_classes.select { |klass| time_form_attributes(klass.new).any? }

      expect(edited).to include(UserDashboard)
      edited.each do |klass|
        controller = "SuperAdmin::#{klass.name.delete_suffix('Dashboard').pluralize}Controller".constantize

        expect(resource_params_owners(controller)).to include(SuperAdmin::ApplicationController), klass.name
      end
    end

    it 'converts the time of an attribute of any dashboard, whatever the controller' do
      types = {
        confirmed_at: ConfirmedAtField, created_at: Administrate::Field::DateTime, name: Administrate::Field::String,
        note: Administrate::Field::String.with_options(searchable: true)
      }
      dashboard = instance_double(UserDashboard, attribute_types: types)
      controller = SuperAdmin::UsersController.new
      allow(controller).to receive(:dashboard).and_return(dashboard)

      expect(controller.send(:astana_input_attributes)).to eq(%i[confirmed_at created_at])
    end

    it 'saves the time of an edit form as the same moment, for a date and time the controller lists' do
      patch "/super_admin/users/#{create(:user).id}", params: { user: { confirmed_at: '2026-10-15T00:30' } }

      expect(User.order(:id).last.confirmed_at).to eq(Time.utc(2026, 10, 14, 19, 30))
    end
  end
end
