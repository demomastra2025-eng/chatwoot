class CaptainListener < BaseListener
  include ::Events::Types

  def conversation_resolved(event)
    conversation = extract_conversation_and_account(event)[0]
    # The dialog is over: no agent leads the next suggestions of «Предложить ответ» (see ReplySuggestion::StickyAgent).
    Captain::ReplySuggestion::StickyAgent.clear!(conversation)
  end

  # A manager's message after a dismissed reply suggestion is recorded on the dismissal (what they wrote instead). A message the
  # manager wrote by hand ends the lead of the sticky agent of «Предложить ответ» (see ReplySuggestion::StickyAgent::ManualReply).
  def message_created(event)
    message = event.data[:message]
    Captain::ReplySuggestion::StickyAgent::ManualReply.mark!(message)
    track_dismissal(message)
    capture_shadow_training(message)
  end

  private

  def capture_shadow_training(message)
    Captain::ShadowTraining::CaptureService.call(message)
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][CaptainListener] shadow capture skipped: #{e.class}")
  end

  def track_dismissal(message)
    Captain::ReplySuggestion::DismissalTracker.message_created(message)
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][CaptainListener] dismissal tracking skipped: #{e.class}: #{e.message}")
  end
end
