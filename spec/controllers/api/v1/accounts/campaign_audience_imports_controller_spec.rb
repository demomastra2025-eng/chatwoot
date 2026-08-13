require 'rails_helper'

RSpec.describe 'Campaign audience imports API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_sms, account: account)) }

  def uploaded_csv(content = "phone_number,name\n87051234567,Recipient\n")
    Rack::Test::UploadedFile.new(StringIO.new(content), 'text/csv', original_filename: 'recipients.csv')
  end

  it 'creates an account-scoped pending import and enqueues processing for administrators' do
    expect do
      post "/api/v1/accounts/#{account.id}/campaign_audience_imports",
           params: { inbox_id: inbox.id, default_country: 'KZ', file: uploaded_csv },
           headers: administrator.create_new_auth_token
    end.to have_enqueued_job(Campaigns::ProcessAudienceImportJob)

    expect(response).to have_http_status(:accepted)
    body = response.parsed_body
    expect(body).to include(
      'status' => 'pending',
      'source_filename' => 'recipients.csv',
      'recipient_count' => 0
    )
    expect(body['token']).to be_present
    expect(account.campaign_audience_imports.find_by!(token: body['token']).import_file).to be_attached
  end

  it 'fails closed and purges the source file when enqueueing is unavailable' do
    allow(Campaigns::ProcessAudienceImportJob).to receive(:perform_later).and_raise(StandardError, 'queue unavailable')
    allow(Rails.logger).to receive(:error)

    post "/api/v1/accounts/#{account.id}/campaign_audience_imports",
         params: { inbox_id: inbox.id, default_country: 'KZ', file: uploaded_csv },
         headers: administrator.create_new_auth_token

    audience_import = account.campaign_audience_imports.order(:id).last
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body['error']).to eq('processing_unavailable')
    expect(audience_import).to be_failed
    expect(audience_import.processing_error).to eq('processing_failed')
    expect(Campaigns::PurgeAudienceImportSourceJob).to have_been_enqueued.with(audience_import.id)

    Campaigns::PurgeAudienceImportSourceJob.perform_now(audience_import.id)

    expect(audience_import.import_file).not_to be_attached
  end

  it 'does not overwrite a completed import when enqueue acknowledgement is lost' do
    allow(Campaigns::ProcessAudienceImportJob).to receive(:perform_later) do |audience_import|
      audience_import.update!(status: :completed)
      raise IOError, 'acknowledgement lost'
    end
    allow(Rails.logger).to receive(:error)

    post "/api/v1/accounts/#{account.id}/campaign_audience_imports",
         params: { inbox_id: inbox.id, default_country: 'KZ', file: uploaded_csv },
         headers: administrator.create_new_auth_token

    audience_import = account.campaign_audience_imports.order(:id).last
    expect(response).to have_http_status(:accepted)
    expect(audience_import.reload).to be_completed
    expect(audience_import.processing_error).to be_nil
    expect(Campaigns::PurgeAudienceImportSourceJob).to have_been_enqueued.with(audience_import.id)
  end

  it 'does not overwrite a failed import when enqueue acknowledgement is lost' do
    allow(Campaigns::ProcessAudienceImportJob).to receive(:perform_later) do |audience_import|
      audience_import.update!(status: :failed, processing_error: 'phone_column_required')
      raise IOError, 'acknowledgement lost'
    end
    allow(Rails.logger).to receive(:error)

    post "/api/v1/accounts/#{account.id}/campaign_audience_imports",
         params: { inbox_id: inbox.id, default_country: 'KZ', file: uploaded_csv },
         headers: administrator.create_new_auth_token

    audience_import = account.campaign_audience_imports.order(:id).last
    expect(response).to have_http_status(:accepted)
    expect(audience_import.reload).to be_failed
    expect(audience_import.processing_error).to eq('phone_column_required')
    expect(Campaigns::PurgeAudienceImportSourceJob).to have_been_enqueued.with(audience_import.id)
  end

  it 'retains a durable failed import and purges an upload with a lost acknowledgement', :aggregate_failures do
    uploaded_blob = nil
    allow(ActiveStorage::Blob).to receive(:build_after_unfurling).and_wrap_original do |original, **args|
      uploaded_blob = original.call(**args)
      allow(uploaded_blob).to receive(:upload_without_unfurling).and_wrap_original do |upload, *upload_args|
        upload.call(*upload_args)
        raise IOError, 'upload acknowledgement lost'
      end
      uploaded_blob
    end
    allow(Rails.logger).to receive(:error)

    post "/api/v1/accounts/#{account.id}/campaign_audience_imports",
         params: { inbox_id: inbox.id, default_country: 'KZ', file: uploaded_csv },
         headers: administrator.create_new_auth_token

    audience_import = account.campaign_audience_imports.order(:id).last
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body['error']).to eq('processing_unavailable')
    expect(audience_import).to be_failed
    expect(audience_import.import_file).to be_attached
    expect(ActiveStorage::Blob.where(id: uploaded_blob.id)).to exist
    expect(ActiveStorage::Blob.service).to exist(uploaded_blob.key)
    expect(Campaigns::PurgeAudienceImportSourceJob).to have_been_enqueued.with(audience_import.id)

    Campaigns::PurgeAudienceImportSourceJob.perform_now(audience_import.id)

    expect(audience_import.reload.import_file).not_to be_attached
    expect(ActiveStorage::Blob.where(id: uploaded_blob.id)).not_to exist
    expect(ActiveStorage::Blob.service).not_to exist(uploaded_blob.key)
  end

  it 'rejects agents and unsupported inboxes without creating an import' do
    post "/api/v1/accounts/#{account.id}/campaign_audience_imports",
         params: { inbox_id: inbox.id, default_country: 'KZ', file: uploaded_csv },
         headers: agent.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)

    email_inbox = create(:channel_email, account: account).inbox
    expect do
      post "/api/v1/accounts/#{account.id}/campaign_audience_imports",
           params: { inbox_id: email_inbox.id, default_country: 'KZ', file: uploaded_csv },
           headers: administrator.create_new_auth_token
    end.not_to change(CampaignAudienceImport, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('unsupported_inbox')
  end

  it 'does not expose another account import by token' do
    other_account = create(:account)
    other_import = create(:campaign_audience_import, account: other_account)

    get "/api/v1/accounts/#{account.id}/campaign_audience_imports/#{other_import.id}",
        headers: administrator.create_new_auth_token

    expect(response).to have_http_status(:not_found)
  end

  it 'returns the terminal import report for polling' do
    audience_import = create(
      :campaign_audience_import,
      account: account,
      inbox: inbox,
      recipient_count: 3,
      created_count: 2,
      existing_count: 1,
      duplicate_count: 1,
      invalid_count: 1,
      error_samples: [{ row: 4, code: 'invalid_phone' }]
    )

    get "/api/v1/accounts/#{account.id}/campaign_audience_imports/#{audience_import.id}",
        headers: administrator.create_new_auth_token

    expect(response).to have_http_status(:success)
    expect(response.parsed_body).to include(
      'status' => 'completed',
      'recipient_count' => 3,
      'created_count' => 2,
      'existing_count' => 1,
      'duplicate_count' => 1,
      'invalid_count' => 1
    )
  end
end
