# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Storage API', type: :request do
  # Single-record attachment lookups (user avatars) are fine; scans over messages, blobs or whole attachment sets are not.
  def scanning_statements(statements)
    statements.select do |sql|
      sql.match?(/active_storage_blobs|FROM "messages"/i) ||
        (sql.include?('active_storage_attachments') && sql.exclude?('"record_id" = $'))
    end
  end

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:storage_test_cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(storage_test_cache)
    Redis::Alfred.delete("account:#{account.id}:storage_overview_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_refresh_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_pending_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_pending_v2")
    Redis::Alfred.delete("account:#{account.id}:storage_generation_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_heavy_recordings_v1")
  end

  after do
    Redis::Alfred.delete("account:#{account.id}:storage_overview_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_refresh_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_pending_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_pending_v2")
    Redis::Alfred.delete("account:#{account.id}:storage_generation_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_heavy_recordings_v1")
  end

  describe 'GET /api/v1/accounts/{account.id}/storage' do
    context 'when unauthenticated' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/storage"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when non-admin user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/storage",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when administrator' do
      it 'returns a calculating state on a cold cache and enqueues one refresh' do
        expect do
          get "/api/v1/accounts/#{account.id}/storage",
              headers: admin.create_new_auth_token,
              as: :json
        end.to have_enqueued_job(Accounts::StorageBreakdownRefreshJob).with(account.id)

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['storage']).to include('calculating' => true, 'breakdown' => nil)
      end

      it 'coalesces repeated cold requests into one refresh job' do
        headers = admin.create_new_auth_token
        expect do
          2.times { get "/api/v1/accounts/#{account.id}/storage", headers: headers, as: :json }
        end.to have_enqueued_job(Accounts::StorageBreakdownRefreshJob).with(account.id).once
      end

      it 'serves a warm snapshot without recalculating or enqueuing' do
        snapshot = Accounts::StorageOverviewService.new(account: account).refresh!
        statements = []
        subscriber = ->(*, payload) { statements << payload[:sql] }
        expect do
          ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
            get "/api/v1/accounts/#{account.id}/storage",
                headers: admin.create_new_auth_token,
                as: :json
          end
        end.not_to have_enqueued_job(Accounts::StorageBreakdownRefreshJob)

        expect(response).to have_http_status(:success)
        expect(scanning_statements(statements)).to be_empty
        expect(response.parsed_body['storage']).to include(
          'calculating' => false,
          'consumed_bytes' => snapshot[:limits][:consumed],
          'breakdown' => snapshot[:breakdown].deep_stringify_keys
        )
      end

      it 'does not scan messages or blobs in the request for an account with many messages' do
        create_list(:message, 50, account: account)
        statements = []
        subscriber = ->(*, payload) { statements << payload[:sql] }

        ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
          get "/api/v1/accounts/#{account.id}/storage",
              headers: admin.create_new_auth_token,
              as: :json
        end

        expect(response).to have_http_status(:success)
        expect(scanning_statements(statements)).to be_empty
      end

      it 'returns the storage overview after the refresh job runs' do
        Accounts::StorageBreakdownRefreshJob.perform_now(account.id)
        get "/api/v1/accounts/#{account.id}/storage",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to have_key('storage')
        expect(json['storage']).to include(
          'total_limit_bytes',
          'consumed_bytes',
          'available_bytes',
          'unlimited',
          'breakdown',
          'last_updated_at'
        )
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/storage/heavy_files' do
    context 'when administrator' do
      it 'returns list of heavy files' do
        expect(Storage::RecordingPaths).not_to receive(:resolve)
        get "/api/v1/accounts/#{account.id}/storage/heavy_files",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to have_key('files')
        expect(json['files']).to be_an(Array)
        expect(json['recordings_pending']).to be(false)
      end

      it 'returns attachment rows while the recording snapshot is pending' do
        message = create(:message, account: account)
        attachment = message.attachments.new(account_id: account.id, file_type: :file)
        attachment.file.attach(io: StringIO.new('fixture'), filename: 'fixture.pdf', content_type: 'application/pdf')
        attachment.save!
        create(:telephony_call_session, account: account, recording_ref: 'legacy.wav')

        get "/api/v1/accounts/#{account.id}/storage/heavy_files",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['files'].pluck('id')).to include("attachment_#{attachment.id}")
        expect(response.parsed_body['recordings_pending']).to be(true)
      end

      it 'returns a clean error when the attachment query times out' do
        service = Accounts::HeavyFilesService.new(account: account, params: { file_type: 'documents' })
        allow(Accounts::HeavyFilesService).to receive(:new).and_return(service)
        allow(service).to receive(:with_statement_timeout).and_raise(ActiveRecord::QueryCanceled, 'statement timeout')

        get "/api/v1/accounts/#{account.id}/storage/heavy_files",
            params: { file_type: 'documents' },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body).to eq('message' => I18n.t('storage_management.errors.heavy_files_timeout', locale: account.locale))
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/storage/refresh' do
    context 'when administrator' do
      it 'queues a refresh and returns the last known snapshot' do
        snapshot = Accounts::StorageOverviewService.new(account: account).refresh!
        expect do
          post "/api/v1/accounts/#{account.id}/storage/refresh",
               headers: admin.create_new_auth_token,
               as: :json
        end.to have_enqueued_job(Accounts::StorageBreakdownRefreshJob).with(account.id)

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json['success']).to be(true)
        expect(json['refresh_status']).to eq('queued')
        expect(json['storage']['breakdown']).to eq(snapshot[:breakdown].deep_stringify_keys)
      end

      it 'reports an existing pending refresh without claiming that another job was queued' do
        headers = admin.create_new_auth_token
        Accounts::StorageOverviewService.new(account: account).schedule_refresh(force: true)

        expect do
          post "/api/v1/accounts/#{account.id}/storage/refresh", headers: headers, as: :json
        end.not_to have_enqueued_job(Accounts::StorageBreakdownRefreshJob)

        expect(response.parsed_body).to include('success' => true, 'refresh_status' => 'pending')
        expect(response.parsed_body['storage']).to include('refresh_pending' => true)
      end

      it 'returns an explicit unavailable response when a refresh cannot be queued' do
        job = Accounts::StorageBreakdownRefreshJob.new(account.id)
        allow(Accounts::StorageBreakdownRefreshJob).to receive(:new).and_return(job)
        allow(job).to receive(:enqueue).and_raise(StandardError, 'queue unavailable')

        post "/api/v1/accounts/#{account.id}/storage/refresh", headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body).to include('success' => false, 'refresh_status' => 'failed')
        expect(response.parsed_body['storage']).to include('refresh_pending' => false)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/storage/preview_cleanup' do
    context 'when administrator' do
      it 'returns preview summary of files to be cleaned' do
        post "/api/v1/accounts/#{account.id}/storage/preview_cleanup",
             params: { file_type: 'all', older_than_months: 6 },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to include('total_count', 'total_bytes', 'samples', 'retention_days')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/storage/move_to_trash' do
    context 'when administrator' do
      it 'moves files matching criteria to trash' do
        headers = admin.create_new_auth_token
        post "/api/v1/accounts/#{account.id}/storage/preview_cleanup",
             params: { file_type: 'all', older_than_months: 6 }, headers: headers, as: :json
        preview_token = response.parsed_body['confirmation_token']
        headers = headers.merge(response.headers.slice('access-token', 'client', 'uid'))
        post "/api/v1/accounts/#{account.id}/storage/move_to_trash",
             params: { file_type: 'all', older_than_months: 6, preview_token: preview_token, confirmed: true },
             headers: headers,
             as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to include('success', 'moved_count', 'freed_bytes', 'expires_at')
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/storage/trash' do
    context 'when administrator' do
      it 'lists files in trash' do
        get "/api/v1/accounts/#{account.id}/storage/trash",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to include('total_count', 'total_bytes', 'items')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/storage/restore_trash' do
    context 'when administrator' do
      it 'restores items from trash' do
        post "/api/v1/accounts/#{account.id}/storage/restore_trash",
             params: { restore_all: true },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to include('success', 'restored_count')
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/storage/empty_trash' do
    context 'when administrator' do
      it 'empties trash' do
        delete "/api/v1/accounts/#{account.id}/storage/empty_trash",
               params: { confirmed: true }, headers: admin.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to include('success', 'purged_count')
      end
    end
  end

  describe 'parameter validation' do
    let(:headers) { admin.create_new_auth_token }

    it 'rejects a cleanup without a usable age instead of trashing every file' do
      %w[0 -1 abc].each do |months|
        post "/api/v1/accounts/#{account.id}/storage/move_to_trash",
             params: { file_type: 'all', older_than_months: months }, headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['message']).to eq(I18n.t('storage_management.errors.invalid_age_filter', locale: account.locale))
      end
    end

    it 'does not turn a half-specified delete into "empty the whole trash"' do
      attachment = create(:message, account: account).attachments.new(account_id: account.id, file_type: :file)
      attachment.file.attach(io: StringIO.new('x'), filename: 'a.pdf', content_type: 'application/pdf')
      attachment.save!
      attachment.update!(meta: { 'trash' => { 'bytes' => 1, 'expires_at' => 5.days.from_now.iso8601 } })

      delete "/api/v1/accounts/#{account.id}/storage/empty_trash", params: { item_type: 'attachment' }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Attachment.exists?(attachment.id)).to be(true)
    end

    it 'rejects unknown item types when restoring' do
      post "/api/v1/accounts/#{account.id}/storage/restore_trash", params: { item_type: 'conversation', item_id: 1 },
                                                                   headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'reports how much quota a move released and how much is pending' do
      post "/api/v1/accounts/#{account.id}/storage/preview_cleanup",
           params: { file_type: 'all', older_than_months: 6 }, headers: headers, as: :json
      preview_token = response.parsed_body['confirmation_token']
      auth_headers = headers.merge(response.headers.slice('access-token', 'client', 'uid'))
      post "/api/v1/accounts/#{account.id}/storage/move_to_trash",
           params: { file_type: 'all', older_than_months: 6, preview_token: preview_token, confirmed: true },
           headers: auth_headers, as: :json

      expect(response.parsed_body).to include('moved_bytes' => 0, 'freed_bytes' => 0, 'pending_bytes' => 0)
    end
  end
end
