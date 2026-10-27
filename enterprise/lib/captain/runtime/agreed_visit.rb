# frozen_string_literal: true

# The visit a conversation has agreed, as plain data for the router and for the check of a silence (Captain::SilenceCheck): the starts
# of the upcoming appointments booked from the chat of the contact (times, "HH:MM" in the zone of each appointment), and whether a
# booking or a move waits for the approval of staff in the conversation (pending). Database and Redis reads only, never a model call.
#
# A confirmation that the patient will come («спасибо, буду») is a courtesy only when there is a visit to confirm, and a «да» to a time
# is an acceptance unless that time is the one of a visit that exists. The visits are read as they stood when the patient wrote: a
# suggestion is made when the operator asks for it, hours later, and the visit of a reminder the patient answered may have ended by then.
class Captain::Runtime::AgreedVisit
  BOOKING_CARD_TOOLS = %w[create_appointment update_appointment].freeze

  attr_reader :times

  def initialize(times: [], pending: false)
    @times = Array(times).map(&:to_s).compact_blank.uniq
    @pending = pending == true
  end

  NONE = new.freeze

  def pending? = @pending

  # An upcoming appointment, or a booking waiting for approval.
  def agreed? = @pending || @times.any?

  class << self
    # conversation: the conversation of the turn (nil for a run without one: nothing is agreed). now: the moment the patient wrote the
    # message the turn answers; a visit that had not ended by then counts. Never raises: an unreadable store is no agreed visit, which
    # only makes the check stricter.
    def for(conversation, now: Time.current)
      return NONE if conversation.blank? || conversation.contact_id.blank?

      account = conversation.account
      context = Captain::AppointmentContext.new(account: account, conversation: conversation)
      new(times: context.upcoming_booked_clocks(now: now), pending: pending_card?(account.id, conversation.id))
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][AgreedVisit] not read: #{e.class}")
      NONE
    end

    private

    def pending_card?(account_id, conversation_id)
      cards = Captain::ReplySuggestion::ActionApprovalService.pending_for(account_id: account_id, conversation_id: conversation_id)
      cards.any? { |card| BOOKING_CARD_TOOLS.include?(Captain::Runtime::ToolFailure.canonical_name(card['tool_name'])) }
    end
  end
end
