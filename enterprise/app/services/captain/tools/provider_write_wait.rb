# An agent tool that changes a MedElement-linked appointment answers only after MedElement answered the write the tool
# started: the calendar talks to MedElement, the agent only ever talks to the calendar. MedElement's OK is final (a
# slower cached server may keep showing the old data for a while, nothing is read back or awaited after it). Any other end
# is a technical failure of the tool: an explicit rejection, a failure, an unknown result, or no answer within the timeout.
# Only a taken slot is a business outcome, because the agent can act on it by offering another time.
class Captain::Tools::ProviderWriteWait
  DEFAULT_TIMEOUT_SECONDS = 20
  POLL_SECONDS = 0.2
  TIMEOUT_ENV_KEY = 'CAPTAIN_PROVIDER_WRITE_TIMEOUT_SECONDS'.freeze
  PATIENT_ACTION_STATUSES = %w[awaiting_patient_selection awaiting_patient_creation awaiting_phone_refresh].freeze
  # Command failure codes that mean "this time is not free": the agent offers another time instead of handing over.
  BUSINESS_FAILURES = {
    'slot_conflict' => 'SLOT_CONFLICT',
    'slot_unavailable' => 'APPOINTMENT_SLOT_UNAVAILABLE'
  }.freeze

  class << self
    def timeout_seconds
      configured = Float(ENV.fetch(TIMEOUT_ENV_KEY, DEFAULT_TIMEOUT_SECONDS), exception: false)
      configured&.positive? ? configured : DEFAULT_TIMEOUT_SECONDS
    end

    def failed?(command)
      command.status.in?(%w[failed declined cancelled]) || PATIENT_ACTION_STATUSES.include?(command.logical_status)
    end

    def unresolved?(command)
      command.provider_status_unknown? || command.reconciliation_required?
    end

    # The error that says how a failed command ended: a taken slot is a business failure, everything else is technical.
    def failure_error(command, technical_code: 'MEDELEMENT_WRITE_FAILED')
      business_code = BUSINESS_FAILURES[command.last_error_code.to_s] if command.failed?
      return Scheduling::Error.new(code: business_code, message: 'The time is not available in Medelement', status: :conflict) if business_code

      Scheduling::Error.new(code: technical_code, message: 'Medelement did not accept the change; staff verification is required',
                            status: :unprocessable_content)
    end
  end

  def initialize(command:, timeout: self.class.timeout_seconds, poll: POLL_SECONDS, sleeper: ->(seconds) { Kernel.sleep(seconds) },
                 clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @command = command
    @timeout = timeout
    @poll = poll
    @sleeper = sleeper
    @clock = clock
  end

  # Returns the command once MedElement answered OK. Otherwise raises the Scheduling::Error that classifies the failure.
  def perform
    deadline = clock.call + timeout
    loop do
      command.reload
      return command if command.succeeded?
      raise self.class.failure_error(command) if self.class.failed?(command)
      raise error('MEDELEMENT_WRITE_UNKNOWN', 'Medelement result is unknown; staff verification is required') if self.class.unresolved?(command)
      return give_up! if clock.call >= deadline

      sleeper.call(poll)
    end
  end

  private

  attr_reader :clock, :command, :poll, :sleeper, :timeout

  # No answer in time. A command that MedElement has not been asked yet is withdrawn, so it cannot book, move or cancel after
  # the agent reported a failure and a human took the conversation over; one that is already running is left to finish.
  def give_up!
    withdrawn = Integrations::Medelement::ProviderCommands::UnstartedWithdrawal.new(command: command).perform
    command.reload
    return command if command.succeeded?
    raise self.class.failure_error(command) if !withdrawn && self.class.failed?(command)

    raise error('MEDELEMENT_WRITE_TIMEOUT', 'Medelement did not answer in time; staff verification is required')
  end

  def error(code, message)
    Scheduling::Error.new(code: code, message: message, status: :unprocessable_content)
  end
end
