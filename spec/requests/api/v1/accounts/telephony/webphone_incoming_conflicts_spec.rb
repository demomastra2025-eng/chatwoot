require 'rails_helper'

# The browsers of one physical call report their legs at the same moment and
# touch the same contact and conversation: a lost deadlock or a failed
# statement must never turn into a 500 for the browser.
RSpec.describe 'Telephony Webphone incoming report under conflicts', type: :request do
  include_context 'with three Beeline operator browsers'

  # Replaces a method of the service objects the report builds for itself.
  def wrap_method_of(klass, method_name, &)
    allow(klass).to receive(:new).and_wrap_original do |original, **args|
      original.call(**args).tap { |object| allow(object).to receive(method_name).and_wrap_original(&) }
    end
  end

  it 'takes the intake lock of the caller before it touches any row' do
    order = []
    allow(Telephony::CallIntakeLock).to receive(:with_lock).and_wrap_original do |original, **args, &block|
      order << [:lock, args[:account_id]]
      original.call(**args, &block)
    end
    allow(Telephony::InboundRoutingService).to receive(:new).and_wrap_original do |original, **args|
      order << :routing
      original.call(**args)
    end

    report_leg(profiles.first, 'sip-call-id-lock')

    expect(order.first).to eq([:lock, account.id])
    expect(order).to include(:routing)
  end

  describe 'a deadlock between sibling legs' do
    it 'is retried and the browser gets its answer instead of a 500' do
      attempts = 0
      wrap_method_of(Telephony::WebphoneService, :perform_browser_sip_incoming_route) do |original, *args|
        attempts += 1
        raise ActiveRecord::Deadlocked, 'simulated deadlock' if attempts == 1

        original.call(*args)
      end

      report_leg(profiles.first, 'sip-call-id-deadlock')

      expect(attempts).to eq(2)
      expect(leg_session(profiles.first, 'sip-call-id-deadlock')).to be_persisted
      expect(account.telephony_call_sessions.count).to eq(1)
    end

    it 'gives up with an error only after the bounded number of retries' do
      attempts = 0
      wrap_method_of(Telephony::WebphoneService, :perform_browser_sip_incoming_route) do |_original, *|
        attempts += 1
        raise ActiveRecord::Deadlocked, 'simulated deadlock'
      end

      expect do
        Telephony::WebphoneService.new(account: account).report_browser_sip_incoming!(
          user: profiles.first.user, inbox: channel.inbox, params: leg_params(profiles.first, 'sip-call-id-deadlock')
        )
      end.to raise_error(ActiveRecord::Deadlocked)
      expect(attempts).to eq(Telephony::EventsIngestionService::SIDE_EFFECT_CONFLICT_RETRIES + 1)
    end
  end

  describe 'a failing fast incoming card' do
    it 'does not abort the report: the database error rolls back its savepoint only' do
      failures = 0
      wrap_method_of(Telephony::InboundRoutingService, :ensure_fast_incoming_call_session!) do |original, *args|
        failures += 1
        ActiveRecord::Base.connection.execute('SELECT 1 / 0') if failures == 1
        original.call(*args)
      end

      report_leg(profiles.first, 'sip-call-id-fast-card')

      expect(leg_session(profiles.first, 'sip-call-id-fast-card')).to be_persisted
    end

    it 'is retried once after a deadlock and still announces the call' do
      failures = 0
      wrap_method_of(Telephony::InboundRoutingService, :ensure_fast_incoming_call_session!) do |original, *args|
        failures += 1
        raise ActiveRecord::Deadlocked, 'simulated deadlock' if failures == 1

        original.call(*args)
      end

      report_leg(profiles.first, 'sip-call-id-fast-retry')

      expect(failures).to eq(2)
      expect(ActionCable.server).to have_received(:broadcast)
        .with(profiles.first.user.pubsub_token, hash_including(event: 'voice_call.incoming')).once
    end
  end
end
