# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Super admin clinic channels', type: :request do
  let!(:super_admin) { create(:super_admin) }
  let(:account) { create(:account).tap { |record| record.enable_features!('channel_website', 'channel_facebook', 'channel_tiktok') } }

  def admin_request_locale
    ENV.fetch('DEFAULT_LOCALE', I18n.default_locale)
  end

  def flash_text(key)
    I18n.t("super_admin.accounts.flashes.#{key}", locale: admin_request_locale)
  end

  def page = Nokogiri::HTML(response.body)

  def row(key) = page.at_css("tr[data-channel=\"#{key}\"]")

  def selected_state(key) = row(key).at_css('select option[selected]')['value']

  def status_badge(key) = row(key).css('td')[1].text.squish

  def overrides = account.reload.custom_attributes['channel_overrides']

  describe 'POST /super_admin/accounts/:id/channel_overrides' do
    it 'sends an unauthenticated visitor to the login and changes nothing' do
      post "/super_admin/accounts/#{account.id}/channel_overrides", params: { overrides: { api: 'shown' } }

      expect(response).to have_http_status(:redirect)
      expect(overrides).to be_nil
    end

    it 'does not let a clinic administrator reach it' do
      sign_in(create(:user, account: account, role: :administrator))

      post "/super_admin/accounts/#{account.id}/channel_overrides", params: { overrides: { api: 'shown' } }

      expect(response).to have_http_status(:redirect)
      expect(overrides).to be_nil
    end

    context 'when signed in as a super admin' do
      before { sign_in(super_admin, scope: :super_admin) }

      it 'stores the exceptions of the clinic, answers in Russian and records who did it' do
        post "/super_admin/accounts/#{account.id}/channel_overrides",
             params: { overrides: { 'api' => 'shown', 'website' => 'hidden', 'facebook' => 'default' } }

        expect(response).to redirect_to("/super_admin/accounts/#{account.id}")
        expect(flash[:notice]).to eq(flash_text(:channel_overrides_saved))
        expect(overrides).to eq('api' => 'shown', 'website' => 'hidden')
        audit = Audited::Audit.where(auditable_id: account.id, auditable_type: 'Account', action: 'update_channel_override').sole
        expect(audit).to have_attributes(user_id: super_admin.id, comment: 'super_admin')
        expect(audit.remote_address).to be_present
        expect(audit.audited_changes['channels']).to eq(
          'api' => { 'from' => nil, 'to' => 'shown' },
          'website' => { 'from' => nil, 'to' => 'hidden' }
        )
      end

      it 'changes what the clinic is offered, for this clinic only' do
        other_account = create(:account)

        post "/super_admin/accounts/#{account.id}/channel_overrides", params: { overrides: { 'api' => 'shown' } }

        expect(Accounts::AvailableChannels.available?(account.reload, 'api')).to be(true)
        expect(Accounts::AvailableChannels.available?(other_account, 'api')).to be(false)
      end

      it 'takes an exception back with «default»' do
        show_channels_for(account, 'api')

        post "/super_admin/accounts/#{account.id}/channel_overrides", params: { overrides: { 'api' => 'default' } }

        expect(overrides).to be_nil
        expect(account.reload.custom_attributes).not_to have_key('channel_overrides')
      end

      it 'says nothing changed, and audits nothing, when the form repeats the current state' do
        show_channels_for(account, 'api')
        audits_before = Audited::Audit.where(action: 'update_channel_override').count

        post "/super_admin/accounts/#{account.id}/channel_overrides", params: { overrides: { 'api' => 'shown', 'website' => 'default' } }

        expect(flash[:notice]).to eq(flash_text(:channel_overrides_unchanged))
        expect(Audited::Audit.where(action: 'update_channel_override').count).to eq(audits_before)
      end

      it 'refuses an unknown channel or state and changes nothing' do
        post "/super_admin/accounts/#{account.id}/channel_overrides", params: { overrides: { 'api' => 'shown', 'ghost' => 'shown' } }
        expect(flash[:alert]).to eq(flash_text(:channel_overrides_invalid))

        post "/super_admin/accounts/#{account.id}/channel_overrides", params: { overrides: { 'api' => 'maybe' } }
        expect(flash[:alert]).to eq(flash_text(:channel_overrides_invalid))

        post "/super_admin/accounts/#{account.id}/channel_overrides", params: { overrides: { 'api' => %w[shown] } }
        expect(flash[:alert]).to eq(flash_text(:channel_overrides_invalid))

        expect(overrides).to be_nil
      end

      describe 'a malformed form' do
        let(:malformed) do
          [
            { overrides: 'api' },
            { overrides: %w[api shown] },
            { overrides: [{ 'api' => 'shown' }] },
            { overrides: { 'api' => 'shown' }, previous: %w[api] }
          ]
        end

        it 'answers 422 with a Russian message, shows the clinic card again and changes nothing' do
          malformed.each do |params|
            post "/super_admin/accounts/#{account.id}/channel_overrides", params: params

            expect(response).to have_http_status(:unprocessable_content), params.inspect
            expect(flash[:alert]).to eq(flash_text(:channel_overrides_malformed))
            expect(page.at_css('.flash-alert').text.squish).to eq(flash_text(:channel_overrides_malformed))
            expect(page.at_css('[data-testid="channels-block"]')).to be_present
          end
          expect(overrides).to be_nil
          expect(Audited::Audit.where(action: 'update_channel_override')).to be_empty
        end
      end

      describe 'two administrators with the same card open' do
        let(:as_drawn) { Channels::Catalog.keys.index_with { 'default' } }

        def post_overrides(requested, previous)
          post "/super_admin/accounts/#{account.id}/channel_overrides", params: { overrides: requested, previous: previous }
        end

        it 'does not undo the change of the first one: the second saves only the select he moved' do
          show_channels_for(account, 'api') # the first one opened the API channel after the card was drawn

          post_overrides(as_drawn.merge('sms' => 'shown'), as_drawn)

          expect(flash[:notice]).to eq(flash_text(:channel_overrides_saved))
          expect(overrides).to eq('api' => 'shown', 'sms' => 'shown')
          audit = Audited::Audit.where(action: 'update_channel_override').order(:id).last
          expect(audit.audited_changes['channels']).to eq('sms' => { 'from' => nil, 'to' => 'shown' })
        end

        it 'says nothing changed when the second only presses «Сохранить»' do
          show_channels_for(account, 'api')

          post_overrides(as_drawn, as_drawn)

          expect(flash[:notice]).to eq(flash_text(:channel_overrides_unchanged))
          expect(overrides).to eq('api' => 'shown')
        end

        it 'stops, with a Russian message and nothing saved, when the second moves a select the first moved to another state' do
          show_channels_for(account, 'api')

          post_overrides(as_drawn.merge('api' => 'hidden', 'sms' => 'shown'), as_drawn)

          expect(response).to redirect_to("/super_admin/accounts/#{account.id}")
          expect(flash[:alert]).to eq(flash_text(:channel_overrides_stale))
          expect(overrides).to eq('api' => 'shown')
        end

        it 'is not stopped by a select the first moved to the very state the second asks for' do
          show_channels_for(account, 'api')

          post_overrides(as_drawn.merge('api' => 'shown'), as_drawn)

          expect(flash[:notice]).to eq(flash_text(:channel_overrides_unchanged))
          expect(overrides).to eq('api' => 'shown')
        end
      end
    end
  end

  describe 'the «Каналы аккаунта» card on the clinic page' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'lists every channel with a three-way setting and its state for this clinic', :aggregate_failures do
      show_channels_for(account, 'api')
      hide_channels_for(account, 'website')
      change_platform_channel_visibility('sms' => 'shown')

      get "/super_admin/accounts/#{account.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('translation missing')
      expect(page.at_css('#account-channels-title').text.squish).to eq('Каналы аккаунта')
      expect(page.css('tr[data-channel]').pluck('data-channel')).to eq(Channels::Catalog.keys)
      expect(page.at_css("form[action='/super_admin/accounts/#{account.id}/channel_overrides']")).to be_present

      expect(selected_state('api')).to eq('shown')
      expect(selected_state('website')).to eq('hidden')
      expect(selected_state('facebook')).to eq('default')
      expect(status_badge('api')).to eq('Доступен')
      expect(status_badge('website')).to eq('Скрыт')
      expect(status_badge('facebook')).to eq('Доступен')
      expect(status_badge('sms')).to eq('Доступен')
      expect(status_badge('line')).to eq('Скрыт')
    end

    it 'spells out what «as the platform» means for each channel' do
      get "/super_admin/accounts/#{account.id}"

      expect(row('api').at_css('select option[value="default"]').text).to eq('Как у платформы (скрыт)')
      expect(row('website').at_css('select option[value="default"]').text).to eq('Как у платформы (показан)')
    end

    it 'says so when a shown channel lacks the feature flag of the clinic' do
      account.disable_features!('channel_facebook')

      get "/super_admin/accounts/#{account.id}"

      expect(status_badge('facebook')).to eq('Нет нужной функции')
    end

    it 'posts the whole table with one button' do
      get "/super_admin/accounts/#{account.id}"

      form = page.at_css("form[action='/super_admin/accounts/#{account.id}/channel_overrides']")
      names = form.css('select').pluck('name')
      expect(names).to eq(Channels::Catalog.keys.map { |key| "overrides[#{key}]" })
      expect(form.css('input[type="submit"]').size).to eq(1)
    end

    it 'draws the setting each select had in a hidden field, for the two-administrators check' do
      show_channels_for(account, 'api')

      get "/super_admin/accounts/#{account.id}"

      expect(row('api').at_css('input[type="hidden"][name="previous[api]"]')['value']).to eq('shown')
      expect(row('website').at_css('input[type="hidden"][name="previous[website]"]')['value']).to eq('default')
    end
  end
end
