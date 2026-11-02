require 'rails_helper'

RSpec.describe 'Voice settings assignment lock order', type: :request do
  self.use_transactional_tests = false

  def wait_until_blocked(pid)
    Timeout.timeout(20) do
      loop do
        return if ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))").positive?

        sleep 0.02
      end
    end
  end

  def update_voice_settings(session, surface, account, channel, headers)
    settings = { first_message: 'Ordered business greeting' }
    if surface == :inbox
      session.patch "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}",
                    params: { channel: { provider_config: { ai_voice_settings: settings } } }, headers: headers, as: :json
    elsif surface == :toggle
      ref = channel.inbox.telephony_number_binding.number_ref
      session.post "/api/v1/accounts/#{account.id}/telephony/ai/toggle",
                   params: { number_ref: ref, enabled: false }, headers: headers, as: :json
    else
      ref = channel.inbox.telephony_number_binding.number_ref
      session.post "/api/v1/accounts/#{account.id}/telephony/numbers/#{ref}/route",
                   params: { ai_voice_settings: settings }, headers: headers, as: :json
    end
  end

  %i[inbox route toggle].each do |surface|
    it "orders a real #{surface} write after CaptainInbox assignment without holding the Voice row while waiting" do
      account = create(:account)
      account.enable_features!('channel_voice')
      admin = create(:user, account: account, role: :administrator)
      assistant = create(:captain_assistant, account: account)
      channel = create(:channel_voice, :sipuni, account: account)
      pid_queue = Queue.new
      status_queue = Queue.new
      worker = nil
      CaptainInbox.transaction do
        Telephony::AiVoice::AssistantAssignmentLock.acquire!(channel.inbox.id)
        worker = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            pid_queue << connection.select_value('SELECT pg_backend_pid()')
            session = ActionDispatch::Integration::Session.new(Rails.application)
            update_voice_settings(session, surface, account, channel, { api_access_token: admin.access_token.token })
            status_queue << session.response.status
          end
        end
        wait_until_blocked(pid_queue.pop)
        # NOWAIT proves the waiting HTTP writer has not taken the row lock in
        # the opposite order. Actual CaptainInbox callbacks then re-enter safely.
        channel.lock!('FOR UPDATE NOWAIT')
        CaptainInbox.create!(inbox: channel.inbox, captain_assistant: assistant)
      end
      worker.join(20) || raise('Voice writer did not finish after assignment commit')
      expect(status_queue.pop).to eq(200)
      expect(CaptainInbox.find_by!(inbox_id: channel.inbox.id).captain_assistant_id).to eq(assistant.id)
      if surface == :toggle
        expect(channel.inbox.telephony_number_binding.routing_policy.reload.ai_enabled).to be(false)
      else
        expect(channel.reload.provider_config.dig('ai_voice_settings', 'first_message')).to eq('Ordered business greeting')
      end
    ensure
      worker&.kill if worker&.alive?
    end
  end
end
