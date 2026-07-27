require 'rails_helper'

RSpec.describe 'Medelement Provider Commands API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, name: 'Ivanov Ivan', phone_number: '+77001234567') }
  let(:hook_settings) { attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true) }
  let(:hook) { create(:integrations_hook, :medelement, account: account, settings: hook_settings) }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/provider_commands" }
  let(:headers) { agent.create_new_auth_token }

  before do
    account.enable_features!('scheduling')
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
  end

  it 'creates only an awaiting-confirmation proposal' do
    post path,
         params: {
           hook_id: hook.id,
           contact_id: contact.id,
           operation: 'create_patient',
           idempotency_key: 'patient-proposal-1'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'status')).to eq('awaiting_confirmation')
    expect(response.parsed_body.dig('payload', 'confirmation', 'status')).to eq('pending')
    expect(response.parsed_body.dig('payload', 'confirmation')).not_to have_key('token')
    expect(Integrations::Medelement::ProviderCommand.last).to have_attributes(contact: contact, attempt_count: 0)
  end

  it 'fails closed when write capability is disabled' do
    hook.update!(settings: hook.settings.merge('write_enabled' => false))

    post path,
         params: {
           hook_id: hook.id,
           contact_id: contact.id,
           operation: 'create_patient',
           idempotency_key: 'patient-proposal-disabled'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('MEDELEMENT_WRITE_DISABLED')
  end

  it 'does not resolve a hook from another account' do
    other_account = create(:account).tap { |record| record.enable_features!('scheduling') }
    other_hook = create(:integrations_hook, :medelement, account: other_account)

    post path,
         params: {
           hook_id: other_hook.id,
           contact_id: contact.id,
           operation: 'create_patient',
           idempotency_key: 'cross-account-hook'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:not_found)
  end

  it 'lists only commands from the current account' do
    own_command = create_command(account: account, hook: hook, contact: contact)
    other_account = create(:account).tap { |record| record.enable_features!('scheduling') }
    other_contact = create(:contact, account: other_account)
    other_hook = create(:integrations_hook, :medelement, account: other_account)
    create_command(account: other_account, hook: other_hook, contact: other_contact)

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([own_command.id])
  end

  private

  def create_command(account:, hook:, contact:)
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      status: 'failed',
      idempotency_key: SecureRandom.uuid
    )
  end
end
