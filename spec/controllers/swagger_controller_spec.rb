require 'rails_helper'

describe '/swagger', type: :request do
  describe 'GET /swagger' do
    it 'renders swagger index.html' do
      get '/swagger'
      expect(response).to have_http_status(:success)
      expect(response.body).to include('redoc')
      expect(response.body).to include('/swagger.json')
    end

    it 'returns not found for path traversal attempts' do
      get '/swagger/../config/database.yml'

      expect(response).to have_http_status(:not_found)
    end

    it 'returns not found for missing swagger files' do
      get '/swagger/missing-file.json'

      expect(response).to have_http_status(:not_found)
    end
  end
end
