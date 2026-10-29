# frozen_string_literal: true

# The first words of a draft for the manager, while the agent is still writing it. The agent answers in structured output
# (Captain::SuggestionResponseSchema: patient_language, response_mode, response, operator_note, reasoning, artifact_ids), and the
# text of the draft is its `response` field. This reads that field out of the pieces of JSON the model streams (FieldReader) and
# broadcasts what has been written so far to the manager who asked, at most every INTERVAL_SECONDS.
#
# `response_mode` (reply, suppress, human) precedes `response` in the schema. A provider may still emit the fields in another
# order, so no text is broadcast until the reader has seen an explicit `reply` mode. An answer whose mode comes last is buffered.
# What the draft finally is stays what it was: the same `response` after the same clean-up (AgentRunnerService#guard_public_response)
# and every later rule of the run (safety check, guardrails, the outcome classifier) - the preview is read-only on the side.
#
# It only watches: it never raises into the model call it listens to (a broken preview must not break the run), and it stores
# nothing (a partial text is not a message, not a request field and not in the progress snapshot).
class Captain::ReplySuggestion::DraftStream
  INTERVAL_SECONDS = 0.2
  # A lone first letter is not worth a flash: the first preview waits for a few words (or for the end of the field).
  FIRST_PREVIEW_MIN_CHARS = 12
  # The agent copies the send stamp of a history message into its reply now and then ("[Sat 24.10 09:50]"); the run removes it
  # (Captain::PromptClock.unstamped). A text that may still turn out to start with one is held until it is clear that it does not.
  STAMP_HEAD_LIMIT = 24
  REFUSAL_HEAD_LIMIT = 180
  REFUSAL_HEAD_PREFIXES = "as\\s+an\\s+ai|i'm\\s+sorry|i\\s+am\\s+sorry|sorry\\b|i\\s+apologize|" \
                          "i\\s+(?:cannot|can't|am\\s+(?:not\\s+)?able|am\\s+unable|won't|will\\s+not)|i'm\\s+(?:unable|not\\s+able)"
  REFUSAL_HEAD_PATTERN = /\A(?:#{REFUSAL_HEAD_PREFIXES})\b/i

  # identity: the fields that tell the dashboard whose preview it is (suggestion_request_id, account_id, conversation_id,
  # conversation_record_id). clock: monotonic seconds.
  def initialize(broadcaster:, identity:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @broadcaster = broadcaster
    @identity = identity
    @clock = clock
    @sequence = 0
    @reader = FieldReader.new
    @shown = nil
    @sent_at = nil
    @disabled = false
  end

  # A piece of the model's answer.
  def feed(piece)
    guarded do
      restart if new_document?(piece)
      @reader.feed(piece)
      text = visible_text
      if text.nil?
        clear if @shown
      elsif due?(text)
        publish(text)
      end
    end
  end

  # The model call ended. Send the last words only when the interval permits it; the final result carries the complete draft.
  def finish!
    guarded do
      text = visible_text
      if text.nil?
        clear if @shown
      elsif due?(text)
        publish(text)
      end
    end
  end

  # A new step of the run begins (a tool is about to run, the agent is asked again): whatever was written is not the answer.
  def reset!
    guarded { restart }
  end

  private

  def restart
    clear if @shown
    @reader.reset
  end

  # The model is asked again inside one call when its answer was not valid (Llm::StructuredOutputPolicy): the next document starts
  # after the end of the one before, or after one that was cut. What was shown belongs to the answer that is dropped.
  def new_document?(piece)
    (@reader.done? || @reader.dead?) && piece.lstrip.start_with?('{')
  end

  def guarded
    return if @disabled

    yield
    nil
  rescue StandardError => e
    @disabled = true
    Rails.logger.warn("[CAPTAIN][ReplySuggestion] draft preview stopped: #{e.class}")
  end

  def due?(text)
    return false if text == @shown
    return false if @shown.nil? && text.length < FIRST_PREVIEW_MIN_CHARS && !@reader.closed?

    @sent_at.nil? || @clock.call - @sent_at >= INTERVAL_SECONDS
  end

  def publish(text)
    @shown = text
    @sent_at = @clock.call
    send_preview(text)
  end

  def clear
    @shown = nil
    @sent_at = nil
    send_preview('')
  end

  def send_preview(text)
    @sequence += 1
    @broadcaster.preview(@identity.merge(seq: @sequence, text: text))
  end

  # What the manager is shown: the text of `response` as the run will clean it, or nothing while the model has not shown (yet)
  # that this is a reply for the patient.
  def visible_text
    return if @reader.dead?
    return unless @reader.mode == 'reply'

    text = @reader.text
    return if stamp_may_follow?(text)

    cleaned = Captain::PromptClock.unstamped(text).strip
    return if cleaned.empty? || refusal_may_follow?(cleaned)
    return if Llm::CaptainResponseContentNormalizer.provider_refusal?(cleaned)

    cleaned
  end

  def refusal_may_follow?(cleaned)
    !@reader.closed? && cleaned.length < REFUSAL_HEAD_LIMIT &&
      REFUSAL_HEAD_PATTERN.match?(Llm::CaptainResponseContentNormalizer.normalize_quotes(cleaned))
  end

  def stamp_may_follow?(text)
    head = text.lstrip
    head.start_with?('[') && head.length < STAMP_HEAD_LIMIT && !Captain::PromptClock::STAMP_PATTERN.match?(head)
  end
end
