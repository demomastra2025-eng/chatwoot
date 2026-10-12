# Runs the wait of an agent tool for MedElement's answer on a fake clock: every sleep moves the clock forward instead of
# taking real time, so a timeout example is instant and does not depend on how busy the machine is.
#
#   include_context 'with a fake provider write wait clock'
#   before { allow(Captain::Tools::ProviderWriteWait).to receive(:timeout_seconds).and_return(0.3) }
RSpec.shared_context 'with a fake provider write wait clock' do
  let(:provider_wait_now) { [0.0] }

  before do
    now = provider_wait_now
    clock = -> { now.first }
    sleeper = ->(seconds) { now[0] += seconds }
    [Captain::Tools::ProviderWriteWait, Captain::Tools::ProviderBookingOutcomeService].each do |waiter|
      allow(waiter).to receive(:new).and_wrap_original do |original, **options|
        original.call(**options, clock: clock, sleeper: sleeper)
      end
    end
  end
end
