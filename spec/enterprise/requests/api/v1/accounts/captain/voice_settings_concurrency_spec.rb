require 'rails_helper'

RSpec.describe 'Voice settings concurrent writes', type: :request do
  self.use_transactional_tests = false

  def send_voice_patch(session, surface, account, channel, admin)
    voice = { first_message: 'Concurrent business greeting' }
    headers = { api_access_token: admin.access_token.token }
    if surface == :inbox
      session.patch "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}",
                    params: { channel: { provider_config: { ai_voice_settings: voice } } }, headers: headers, as: :json
    else
      number_ref = channel.inbox.telephony_number_binding.number_ref
      session.post "/api/v1/accounts/#{account.id}/telephony/numbers/#{number_ref}/route",
                   params: { ai_voice_settings: voice }, headers: headers, as: :json
    end
  end

  it 'does not restore a stale channel snapshot when a delayed sync callback runs after a newer commit' do
    account = create(:account)
    channel = create(:channel_voice, :sipuni, account: account)
    stale_channel = Channel::Voice.find(channel.id)
    channel.update!(provider_config: channel.provider_config.merge('ai_voice_settings' => { 'first_message' => 'Latest committed greeting' }))
    Telephony::NumberBinding.sync_from_voice_channel!(stale_channel)
    expect(channel.inbox.telephony_number_binding.routing_policy.reload.ai_voice_settings).to include('first_message' => 'Latest committed greeting')
    expect(stale_channel.provider_config['ai_voice_settings']).to include('first_message' => 'Latest committed greeting')
  end

  %i[inbox route].each do |surface|
    it "merges a real #{surface} write with a concurrent committed provider config write" do
      account = create(:account)
      account.enable_features!('channel_voice')
      admin = create(:user, account: account, role: :administrator)
      channel = create(:channel_voice, :sipuni, account: account)
      worker_pid = Queue.new
      worker = nil
      response_status = Queue.new
      ActiveRecord::Base.transaction do
        channel.lock!
        worker = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            worker_pid << connection.select_value('SELECT pg_backend_pid()')
            session = ActionDispatch::Integration::Session.new(Rails.application)
            send_voice_patch(session, surface, account, channel, admin)
            response_status << session.response.status
          end
        end
        pid = worker_pid.pop
        Timeout.timeout(20) do
          loop do
            break if ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))").positive?

            sleep 0.02
          end
        end
        channel.update!(provider_config: channel.provider_config.merge('display_name' => 'Concurrent provider label',
                                                                       'ai_voice_settings' => { 'closing_message' => 'Concurrent closing' }))
      end
      worker.join(20) || raise('Voice PATCH did not finish after the channel transaction committed')
      expect(response_status.pop).to eq(200)
      expect(channel.reload.provider_config).to include(
        'display_name' => 'Concurrent provider label',
        'ai_voice_settings' => include('first_message' => 'Concurrent business greeting', 'closing_message' => 'Concurrent closing')
      )
    ensure
      worker&.kill if worker&.alive?
    end
  end
end
