# frozen_string_literal: true

# The language of the patient for one agent run (see Captain::PatientLanguageDetector). The decision is started on a thread of its own
# at the start of the run, so it overlaps the building of the history and the run state, the input check and the building of the
# agents; the run waits for it only at the first agent call, which needs the language for its prompt. A decision that fails, runs
# out of time or has no thread to run on gives the language the conversation already has.
module Captain::Assistant::PatientLanguageHelper
  # The detector's own timeout, plus the time of its database reads and of the write after the call.
  LANGUAGE_WAIT_SECONDS = Captain::PatientLanguageDetector::TIMEOUT_SECONDS + 2
  # CAPTAIN_LANGUAGE_PARALLEL=off runs the decision on the calling thread, at the first agent call, as it did before.
  PARALLEL_SWITCH = 'CAPTAIN_LANGUAGE_PARALLEL'
  OFF_VALUES = %w[off 0 false disabled no].freeze

  private

  def start_patient_language_detection
    @patient_language = nil
    @patient_language_decided = false
    @language_thread = nil
    @language_detector = nil
    return unless @conversation

    @language_detector = Captain::PatientLanguageDetector.new(conversation: @conversation)
    @language_thread = spawn_language_thread(@language_detector) if parallel_language_detection?
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][PatientLanguage] not started error_class=#{e.class.name}")
    @language_thread = nil
  end

  # The language for the prompt of the run: decided once, at the first call.
  def patient_language
    return @patient_language if @patient_language_decided

    @patient_language = time_phase('detect_patient_language') { await_patient_language }
    @patient_language_decided = true
    @patient_language
  end

  # A run that ends before its first agent call (the input was blocked, something failed) must not leave the decision running behind
  # it: the thread uses the database and the settings, which the caller may be done with.
  def settle_patient_language_detection
    return unless @language_thread&.alive?

    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { @language_thread.join(LANGUAGE_WAIT_SECONDS) }
  rescue StandardError
    nil
  end

  def await_patient_language
    return unless @language_detector
    return @language_detector.call unless @language_thread

    finished = ActiveSupport::Dependencies.interlock.permit_concurrent_loads { @language_thread.join(LANGUAGE_WAIT_SECONDS) }
    finished ? @language_thread.value : @language_detector.safe_saved_language
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][PatientLanguage] unavailable error_class=#{e.class.name}")
    @language_detector.safe_saved_language
  end

  # The thread gets what the calling thread was started with (current user and account, locale, time zone, event context), see
  # Captain::Runtime::Council::ThreadScope, and the same runtime caches of the settings and the model catalog as the run has. The
  # associations the detector reads are loaded here, not raced for on two threads.
  def spawn_language_thread(detector)
    @conversation.account
    @conversation.communication_thread
    scope = Captain::Runtime::Council::ThreadScope.capture
    Thread.new do
      Thread.current.report_on_exception = false
      scope.run { Llm::Config.with_runtime_cache { with_llm_catalog_snapshots { detector.call } } }
    end
  end

  def parallel_language_detection?
    OFF_VALUES.exclude?(ENV.fetch(PARALLEL_SWITCH, nil).to_s.strip.downcase)
  end
end
