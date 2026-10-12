require 'rails_helper'

RSpec.describe 'Scheduling Cabinets API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/cabinets" }

  before do
    account.enable_features!('scheduling')
  end

  def response_body
    response.parsed_body
  end

  def create_specialist(cabinets, **attributes)
    create(:scheduling_resource, account: account, custom_attributes: { 'medelement_cabinets' => cabinets }, **attributes)
  end

  it 'lists the cabinets of the account for an administrator' do
    create_specialist(
      [
        { 'companyCabinetCode' => '502', 'cabinetName' => 'Процедурный', 'cabinetNumber' => '2', 'cabinetType' => 'procedure' },
        { 'companyCabinetCode' => '501', 'cabinetName' => 'Терапевт', 'cabinetNumber' => '1' }
      ]
    )
    create_specialist([{ 'companyCabinetCode' => '501', 'cabinetName' => 'Терапевт' }])
    create_specialist([{ 'companyCabinetCode' => '503', 'cabinetName' => 'Архив' }], active: false)

    get path, headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body['payload']).to eq(
      [
        { 'code' => '502', 'name' => 'Процедурный', 'number' => '2', 'type' => 'procedure' },
        { 'code' => '501', 'name' => 'Терапевт', 'number' => '1', 'type' => nil }
      ]
    )
    expect(response_body['meta']).to eq('count' => 2)
  end

  it 'allows an agent to read the list like the services list' do
    create_specialist([{ 'companyCabinetCode' => '501', 'cabinetName' => 'Терапевт' }])

    get path, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body['payload'].pluck('code')).to eq(['501'])
  end

  it 'returns an empty list for an account without MedElement cabinets' do
    create(:scheduling_resource, account: account)

    get path, headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body['payload']).to eq([])
  end

  it 'never exposes the cabinets of another account' do
    other_account = create(:account)
    create(:scheduling_resource, account: other_account,
                                 custom_attributes: { 'medelement_cabinets' => [{ 'companyCabinetCode' => '999', 'cabinetName' => 'Foreign' }] })

    get path, headers: admin.create_new_auth_token, as: :json

    expect(response_body['payload']).to eq([])
  end

  it 'rejects the request when scheduling is disabled' do
    account.disable_features!('scheduling')

    get path, headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response_body['code']).to eq('FEATURE_DISABLED')
  end

  it 'requires authentication' do
    get path, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
