require 'rails_helper'
require 'timeout'

RSpec.describe WhatsappWeb::ContactSyncService do
  self.use_transactional_tests = false

  before do
    stub_request(:delete, %r{\Ahttps://evolution\.example\.test/instance/delete/}).to_return(status: 200, body: '{}')
  end

  def create_records
    account = create(:account)
    channel = create(:channel_whatsapp_web, account: account)
    payload = { remoteJid: '15550000011@s.whatsapp.net', pushName: 'Profile Name',
                phonebookName: 'Saved Alias', phonebookNameUpdatedAt: '2026-11-01T12:00:00Z' }
    source = described_class.new(channel: channel, contact_payload: payload).perform
    { account: account, channel: channel, source: source }
  end

  def run_worker(outcome, &)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&)
    rescue StandardError => e
      outcome << e
    ensure
      Current.reset
    end
  end

  def wait_for_waiter_or_completion(pid, completed)
    Timeout.timeout(10) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value(
          "SELECT COUNT(*) FROM pg_locks WHERE pid = #{Integer(pid)} AND locktype = 'advisory' AND NOT granted"
        ).to_i.positive?
        return true if waiting
        return false unless completed.empty?

        sleep 0.02
      end
    end
  end

  it 'serializes a manual API edit after an in-flight provider snapshot and preserves the manual source', :aggregate_failures do
    records = create_records
    admin = create(:user, account: records[:account], role: :administrator)
    headers = admin.create_new_auth_token
    ready = Queue.new
    release = Queue.new
    outcome = Queue.new
    finished = Queue.new
    backend = Queue.new
    service = described_class.new(channel: records[:channel], contact_payload: {
                                    remoteJid: '15550000011@s.whatsapp.net', pushName: 'Later Profile'
                                  })
    allow(service).to receive(:sync_existing_contact).and_wrap_original do |original, *args, **kwargs|
      ready << true
      release.pop
      original.call(*args, **kwargs)
    end
    provider = run_worker(outcome) { service.perform }
    Timeout.timeout(10) { ready.pop }
    manual = run_worker(outcome) do
      backend << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()')
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.patch "/api/v1/accounts/#{records[:account].id}/contacts/#{records[:source].contact_id}",
                    headers: headers, as: :json,
                    params: { name: 'Manual Alias', additional_attributes: { display_preferences: { primary_name_source: { kind: 'manual' } } } }
      outcome << session.response.status
      finished << true
    end
    waited = wait_for_waiter_or_completion(Timeout.timeout(10) { backend.pop }, finished)
    release << true
    [provider, manual].each { |worker| Timeout.timeout(10) { worker.join } }

    expect(waited).to be(true)
    expect(outcome.pop).to eq(200)
    contact = records[:source].contact.reload
    expect(contact.name).to eq('Manual Alias')
    expect(contact.primary_name_source).to eq('kind' => 'manual')
  ensure
    release << true if defined?(release) && release
    provider&.join(10)
    manual&.join(10)
    cleanup_records(records, admin)
  end

  it 'serializes a phonebook rename with an in-flight partial profile upsert', :aggregate_failures do
    records = create_records
    ready = Queue.new
    release = Queue.new
    outcome = Queue.new
    finished = Queue.new
    backend = Queue.new
    partial_service = described_class.new(channel: records[:channel], contact_payload: {
                                            remoteJid: '15550000011@s.whatsapp.net', pushName: 'Later Profile'
                                          })
    allow(partial_service).to receive(:sync_channel_profile).and_wrap_original do |original, *args|
      ready << true
      release.pop
      original.call(*args)
    end
    partial = run_worker(outcome) { partial_service.perform }
    Timeout.timeout(10) { ready.pop }
    rename = run_worker(outcome) do
      backend << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()')
      described_class.new(channel: Channel::WhatsappWeb.find(records[:channel].id), contact_payload: {
                            remoteJid: '15550000011@s.whatsapp.net', pushName: 'Profile Name',
                            phonebookName: 'New Saved Alias', phonebookNameUpdatedAt: '2026-11-02T12:00:00Z'
                          }).perform
      finished << true
    end
    waited = wait_for_waiter_or_completion(Timeout.timeout(10) { backend.pop }, finished)
    release << true
    [partial, rename].each { |worker| Timeout.timeout(10) { worker.join } }

    expect(waited).to be(true)
    expect(outcome).to be_empty
    expect(records[:source].contact.reload.name).to eq('New Saved Alias')
    expect(records[:source].reload.channel_profile.profile_data['phonebook_name']).to eq('New Saved Alias')
  ensure
    release << true if defined?(release) && release
    partial&.join(10)
    rename&.join(10)
    cleanup_records(records)
  end

  def cleanup_records(records, admin = nil)
    return if records.blank?

    account = records[:account]
    ContactChannelProfile.where(account_id: account.id).delete_all
    ContactInbox.where(inbox_id: account.inboxes.select(:id)).delete_all
    Contact.where(account_id: account.id).delete_all
    account.inboxes.destroy_all
    [Crm::FieldDefinition, Crm::TaskOutcome, Crm::TaskType, Crm::TaskStatus].each { |model| model.where(account_id: account.id).delete_all }
    account.destroy!
    admin&.destroy! if admin&.persisted?
  end
end
