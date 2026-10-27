# frozen_string_literal: true

# Helpers for the specs of voice numbers (the only channel whose AI names an agent).
module VoiceInboxHelpers
  # A voice inbox of the account. The Twilio app set-up that a new number triggers is stubbed, so that no request leaves the test.
  def create_voice_inbox(account)
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: 'APtest'))
    create(:inbox, account: account, channel: build(:channel_voice, account: account))
  end
end

RSpec.configure { |config| config.include VoiceInboxHelpers }
