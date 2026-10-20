class CsatSurveyListener < BaseListener
  def conversation_status_changed(_event)
    # Legacy per-channel CSAT survey on conversation resolve is disabled.
    nil
  end

  def message_updated(event)
    message = extract_message_and_account(event)[0]
    return unless message.input_csat?

    CsatSurveys::ResponseBuilder.new(message: message).perform
  end
end
