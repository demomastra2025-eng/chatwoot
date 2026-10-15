require 'rails_helper'

RSpec.describe 'Super Admin shell', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:page) { Nokogiri::HTML(response.body) }

  before { sign_in(super_admin, scope: :super_admin) }

  describe 'flash messages' do
    let(:account_user) { create(:account_user) }

    def fail_destroy_with(*messages)
      # rubocop:disable RSpec/AnyInstance
      allow_any_instance_of(AccountUser).to receive(:destroy) do |record|
        messages.each { |message| record.errors.add(:base, message) }
        false
      end
      # rubocop:enable RSpec/AnyInstance
      delete "/super_admin/account_users/#{account_user.id}"
      follow_redirect!
    end

    it 'escapes the text instead of rendering it as markup' do
      fail_destroy_with('<img src=x onerror=alert(1)>')

      flash_node = page.at_css('.flashes .flash-error')
      expect(flash_node).to be_present
      expect(flash_node.text).to include('<img src=x onerror=alert(1)>')
      expect(flash_node.at_css('img')).to be_nil
      expect(response.body).not_to include('<img src=x onerror')
    end

    it 'shows several error messages on one line' do
      fail_destroy_with('First problem', 'Second problem')

      expect(page.at_css('.flashes .flash-error').text.squish).to eq('First problem, Second problem')
    end

    it 'draws errors as an alert banner with the error tone' do
      fail_destroy_with('Broken')

      flash_node = page.at_css('.flashes .flash-error')
      expect(flash_node['role']).to eq('alert')
      expect(flash_node['class'].split).to include('bg-n-ruby-2', 'text-n-ruby-11')
    end
  end

  describe 'page scripts' do
    it 'does not load the Chatwoot support widget' do
      get '/super_admin/users'

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('chatwootSDK', 'chatwootSettings', '/packs/js/sdk.js', 'support_website_token')
    end

    it 'still loads the Administrate scripts' do
      get '/super_admin/users'

      expect(page.css('script[src]').map { |script| script['src'] }).to include(a_string_matching(%r{/assets/administrate/application}))
    end
  end

  describe 'stylesheets' do
    it 'keeps the Administrate stylesheet before the Vite bundle so the restyle wins by order' do
      get '/super_admin/users'

      sources = page.css('head link[rel="stylesheet"], head script[src]').map { |node| node['href'] || node['src'] }
      administrate = sources.index { |source| source.include?('administrate/application') }
      bundle = sources.index { |source| source.include?('superadmin') }

      expect(administrate).to be_present
      expect(bundle).to be_present
      expect(administrate).to be < bundle
    end
  end

  describe 'sign out' do
    it 'is a plain link in the sidebar' do
      get '/super_admin/users'

      expect(page.at_css('nav a[href="/super_admin/logout"]')).to be_present
    end
  end
end
