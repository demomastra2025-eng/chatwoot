require 'rails_helper'

RSpec.describe 'CRM stage requirement replacement', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:stage) { account.crm_pipelines.find_by!(code: 'sales_pipeline').stages.find_by!(code: 'qualified') }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}/field_requirements" }

  before do
    account.enable_features!('crm_deals')
    Crm::Bootstrap::AccountService.new(account: account).perform
    stage.field_requirements.create!(field_key: 'description', required: true)
  end

  it 'clears requirements with an explicitly empty list' do
    patch path, params: { requirements: [] }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(stage.field_requirements.reload).to be_empty
  end

  [nil, '', {}, 'description', [1], [['description']]].each do |invalid|
    it "rejects #{invalid.inspect} without clearing the previous requirements" do
      patch path, params: { requirements: invalid }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(stage.field_requirements.reload.pluck(:field_key)).to eq(['description'])
    end
  end

  it 'rejects an omitted requirements key' do
    patch path, params: {}, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(stage.field_requirements.reload.pluck(:field_key)).to eq(['description'])
  end

  it 'rolls back a replacement containing an unknown field' do
    patch path, params: { requirements: [{ field_key: 'unknown_field', required: true }] }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(stage.field_requirements.reload.pluck(:field_key)).to eq(['description'])
  end

  it 'does not clear another account stage' do
    another_account = create(:account)
    another_account.enable_features!('crm_deals')
    Crm::Bootstrap::AccountService.new(account: another_account).perform
    another_stage = another_account.crm_pipelines.first.stages.first
    patch "/api/v1/accounts/#{account.id}/crm/stages/#{another_stage.id}/field_requirements",
          params: { requirements: [] }, headers: headers, as: :json

    expect(response).to have_http_status(:not_found)
    expect(stage.field_requirements.reload.pluck(:field_key)).to eq(['description'])
  end
end
