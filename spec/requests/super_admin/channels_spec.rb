# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Super admin channels page', type: :request do
  let!(:super_admin) { create(:super_admin) }
  let(:account) { create(:account) }

  def admin_request_locale
    ENV.fetch('DEFAULT_LOCALE', I18n.default_locale)
  end

  def flash_text(key)
    I18n.t("super_admin.channels.flashes.#{key}", locale: admin_request_locale)
  end

  def page = Nokogiri::HTML(response.body)

  def row(key) = page.at_css("tr[data-channel=\"#{key}\"]")

  def switch(key) = row(key).at_css('input[type="checkbox"]')

  def stored_settings = InstallationConfig.find_by(name: Channels::PlatformVisibility::CONFIG_NAME)&.value

  describe 'access' do
    it 'sends an unauthenticated visitor to the login and saves nothing' do
      get '/super_admin/channels'
      expect(response).to have_http_status(:redirect)

      patch '/super_admin/channels', params: { channels: { api: 'shown' } }
      expect(response).to have_http_status(:redirect)
      expect(stored_settings).to be_nil
    end

    it 'does not let a clinic administrator reach it' do
      sign_in(create(:user, account: account, role: :administrator))

      patch '/super_admin/channels', params: { channels: { api: 'shown' } }

      expect(response).to have_http_status(:redirect)
      expect(stored_settings).to be_nil
    end
  end

  context 'when signed in as a super admin' do
    before { sign_in(super_admin, scope: :super_admin) }

    describe 'GET /super_admin/channels' do
      it 'lists every channel of the catalog, in the shell, with the default switch positions' do
        get '/super_admin/channels'

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('translation missing')
        expect(page.at_css('nav[role="navigation"]')).to be_present
        expect(page.at_css('h1.main-content__page-title').text.squish).to eq('Каналы')
        expect(page.css('tr[data-channel]').pluck('data-channel')).to eq(Channels::Catalog.keys)

        Channels::Catalog.entries.each do |entry|
          expect(switch(entry.key).key?('checked')).to eq(entry.shown_by_default?), "switch of #{entry.key}"
          expect(row(entry.key).text).to include(entry.name)
        end
      end

      it 'marks the page in the sidebar group «Дополнительно»' do
        get '/super_admin/channels'

        group = page.at_css('[role="group"][aria-labelledby="nav-group-extra"]')
        expect(group.css('a').map { |link| link.text.squish }).to include('Каналы')
        expect(page.css('nav a[aria-current="page"]').map { |link| link.text.squish }).to eq(['Каналы'])
      end

      it 'shows how many inboxes exist and how many clinics have an exception' do
        create_list(:channel_api, 2, account: account)
        show_channels_for(account, 'api', 'sms')

        get '/super_admin/channels'

        expect(row('api').css('td').map { |cell| cell.text.squish }.last(2)).to eq(%w[2 1])
        expect(row('sms').css('td').map { |cell| cell.text.squish }.last(2)).to eq(%w[0 1])
        expect(row('line').css('td').map { |cell| cell.text.squish }.last(2)).to eq(%w[0 0])
      end

      it 'shows the switches the platform has set' do
        change_platform_channel_visibility('api' => 'shown', 'website' => 'hidden')

        get '/super_admin/channels'

        expect(switch('api').key?('checked')).to be(true)
        expect(switch('website').key?('checked')).to be(false)
      end

      it 'says the settings were never changed, and later when they were, in Astana time' do
        get '/super_admin/channels'
        expect(response.body).to include(I18n.t('super_admin.channels.never_changed', locale: admin_request_locale))

        travel_to(Time.utc(2026, 10, 15, 12, 0, 0)) { change_platform_channel_visibility('api' => 'shown') }
        get '/super_admin/channels'

        expect(response.body).to include('Последнее изменение: 15.10.2026 17:00 (Астана)')
      end
    end

    describe 'PATCH /super_admin/channels' do
      it 'saves the switches, answers in Russian and shows them again' do
        patch '/super_admin/channels', params: { channels: { 'api' => 'shown', 'facebook' => 'hidden', 'website' => 'shown' } }

        expect(response).to redirect_to('/super_admin/channels')
        expect(flash[:notice]).to eq(flash_text(:saved))
        expect(stored_settings).to eq('api' => 'shown', 'facebook' => 'hidden')

        get '/super_admin/channels'
        expect(switch('api').key?('checked')).to be(true)
        expect(switch('facebook').key?('checked')).to be(false)
      end

      it 'lets the clinics see the change: the channel is created now, and refused after it is switched off again' do
        patch '/super_admin/channels', params: { channels: { 'api' => 'shown' } }
        expect(Accounts::AvailableChannels.available?(account, 'api')).to be(true)

        patch '/super_admin/channels', params: { channels: { 'api' => 'hidden' } }
        expect(Accounts::AvailableChannels.available?(account, 'api')).to be(false)
      end

      it 'records who changed what in the audit log' do
        patch '/super_admin/channels', params: { channels: { 'api' => 'shown', 'tiktok' => 'shown' } }

        audit = Audited::Audit.where(auditable_type: 'InstallationConfig', action: 'update_channel_visibility').sole
        expect(audit).to have_attributes(user_id: super_admin.id, comment: 'super_admin')
        expect(audit.remote_address).to be_present
        expect(audit.audited_changes['channels']).to eq(
          'api' => { 'from' => 'hidden', 'to' => 'shown' },
          'tiktok' => { 'from' => 'hidden', 'to' => 'shown' }
        )
      end

      it 'shows the change in the audit page with its Russian action name' do
        patch '/super_admin/channels', params: { channels: { 'api' => 'shown' } }

        get '/super_admin/audits'

        expect(response.body).to include('Изменение видимости каналов')
      end

      it 'says nothing changed, and audits nothing, when the form repeats the current state' do
        patch '/super_admin/channels', params: { channels: { 'api' => 'hidden', 'website' => 'shown' } }

        expect(response).to redirect_to('/super_admin/channels')
        expect(flash[:notice]).to eq(flash_text(:unchanged))
        expect(stored_settings).to be_nil
        expect(Audited::Audit.where(action: 'update_channel_visibility')).to be_empty
      end

      it 'refuses an unknown channel or state and changes nothing' do
        patch '/super_admin/channels', params: { channels: { 'api' => 'shown', 'ghost' => 'shown' } }
        expect(flash[:alert]).to eq(flash_text(:invalid))

        patch '/super_admin/channels', params: { channels: { 'api' => 'maybe' } }
        expect(flash[:alert]).to eq(flash_text(:invalid))

        patch '/super_admin/channels', params: { channels: 'api' }
        expect(flash[:alert]).to eq(flash_text(:invalid))

        expect(stored_settings).to be_nil
      end
    end
  end
end
