# frozen_string_literal: true

# Whether a patient's short message may end with no reply at all (a plain thanks, an ok, «спасибо, буду»). The decision models of the
# router and the agent itself (response_mode suppress) both may say that no reply is needed; this is the check by the words of the
# message and the facts of the dialog that no model decides, because a wrong silence swallows a request (the review of 27.10: «Да,
# подходит» to a time that staff offered was silenced, and so was a confirmation that the patient will come when nothing was agreed).
# It names the reason a silence is unsafe, or nil when it is safe:
#
#   no_agreed_visit  the patient says that they will come («буду», «придём», «келемін») and the contact has no upcoming appointment and
#                    no booking card that waits for approval: there is nothing to confirm, so it answers an offer.
#   offered_time     the patient accepts («да», «ок», «подходит», «жарайды»), and the last message of the clinic names a time or a date
#                    that is none of an appointment the contact has (see Captain::Runtime::AgreedVisit): it offers it, and the
#                    acceptance books it. A thanks that accepts nothing is not an acceptance.
#
# Only the words of the last message of the clinic are read: the send time the history writes in front of every message ("[Sat 24.10
# 09:50]", see Captain::PromptClock) is no time that the clinic offered. A message of the clinic with no words (a voice note of staff
# whose transcript is missing) offers nothing, so a bare thanks, ok or «буду» after it is a courtesy as it is after any other message.
module Captain::SilenceCheck
  REASONS = %i[no_agreed_visit offered_time].freeze

  module_function

  # text: the patient's messages that the turn answers. last_clinic: the text of the last message of the clinic in the dialog (nil when
  # the dialog has none). visit: Captain::Runtime::AgreedVisit of the contact.
  def unsafe_reason(text:, last_clinic:, visit:)
    coming = Captain::PatientIntent.confirms_visit?(text)
    return :no_agreed_visit if coming && !visit.agreed?

    accepts = coming || Captain::PatientIntent.accepts?(text)
    :offered_time if accepts && offers_time?(last_clinic, visit)
  end

  # The message names a time or a date that the contact has no appointment at: a clock time that is none of the starts of the contact's
  # upcoming appointments, or, without a clock time, a day (today, a weekday, a date) when the contact has no upcoming appointment at all.
  # A booking card that waits for approval covers the times it was prepared for, which are not known here: it covers every time.
  def offers_time?(text, visit)
    text = Captain::PromptClock.unstamped(text)
    return false unless Captain::PatientIntent.names_time?(text)

    clocks = Captain::PatientIntent.clock_times(text)
    return !visit.agreed? if clocks.empty?

    visit.pending? ? false : (clocks - visit.times).any?
  end
end
