require 'rails_helper'

RSpec.describe 'Super Admin access tokens API', type: :request do
  let(:super_admin) { create(:super_admin) }
  let!(:platform_app) { create(:platform_app) }

  describe 'GET /super_admin/access_tokens' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      before { sign_in(super_admin, scope: :super_admin) }

      it 'shows the list of access tokens with the last 4 characters only' do
        get '/super_admin/access_tokens'

        token = platform_app.access_token.token
        expect(response).to have_http_status(:success)
        expect(response.body).to include("••••#{token.last(4)}")
        expect(response.body).not_to include(token)
      end

      it 'never puts the token of a user into the page, with or without a reveal button' do
        user_token = super_admin.access_token.token

        get '/super_admin/access_tokens'

        expect(response.body).not_to include(user_token)
        expect(Nokogiri::HTML(response.body).css('[data-secret-text], [data-secret-toggler], [data-secret-copier]')).to be_empty
      end

      it 'does not let the search box rebuild a token: a piece of it narrows nothing' do
        get '/super_admin/access_tokens', params: { search: platform_app.access_token.token[3, 10] }
        with_a_piece = Nokogiri::HTML(response.body).css('tbody tr').size
        get '/super_admin/access_tokens', params: { search: 'not-a-token-at-all' }
        with_garbage = Nokogiri::HTML(response.body).css('tbody tr').size

        expect(response).to have_http_status(:success)
        expect(with_a_piece).to eq(with_garbage)
        expect(with_a_piece).to eq(AccessToken.count)
        expect(AccessTokenDashboard.new.search_attributes).to be_empty
      end

      it 'has no search box (nothing is searchable) but keeps the filters by owner' do
        get '/super_admin/access_tokens'

        page = Nokogiri::HTML(response.body)
        expect(page.at_css('form.search')).to be_nil
        expect(page.css('.segmented a').map { |link| link.text.squish }.size).to be >= 2
      end

      it 'does not show the token on the card of one token either' do
        token = platform_app.access_token

        get "/super_admin/access_tokens/#{token.id}"

        expect(response).to have_http_status(:success)
        expect(response.body).to include("••••#{token.token.last(4)}")
        expect(response.body).not_to include(token.token)
      end
    end
  end
end
