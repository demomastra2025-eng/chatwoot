# frozen_string_literal: true

class Telephony::Wazo::CallLogCorrelator
  WINDOW = 90.seconds

  def self.find(account:, inbox:, caller:, did:, direction:, started_at:, cdr_ref: nil)
    return if inbox.blank? || caller.blank? || did.blank? || started_at.blank?

    normalized_caller = normalize(caller)
    normalized_did = normalize(did)
    return unless normalized_caller && normalized_did

    candidates = account.telephony_call_sessions.where(provider: 'wazo', inbox_id: inbox.id, direction: direction)
                        .where('COALESCE(started_at, created_at) BETWEEN ? AND ?', started_at - WINDOW, started_at + WINDOW)
                        .order(:id).limit(20)
    matches = candidates.select do |session|
      next false if cdr_ref && session.metadata.to_h.dig('metadata', 'wazo_cdr_ref').present? &&
                    session.metadata.to_h.dig('metadata', 'wazo_cdr_ref') != cdr_ref

      session_caller = direction == 'inbound' ? session.from_number : session.to_number
      session_did = direction == 'inbound' ? session.to_number : session.from_number
      bound_did = session.number_binding&.phone_number || session.inbox&.telephony_number_binding&.phone_number
      normalize(session_caller) == normalized_caller &&
        [session_did, bound_did].any? { |value| normalize(value) == normalized_did }
    end
    matches.first if matches.one?
  end

  def self.normalize(value)
    Contacts::PhoneNumberNormalizer.normalize(value) ||
      Contacts::PhoneNumberNormalizer.normalize(value, default_country: 'KZ')
  end
end
