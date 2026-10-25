# The clinic context of an account: one plain text with the facts every AI agent of the clinic needs (name, branches, hours,
# payment, the data a booking takes, tone). Captain::Assistant#prompt_context gives it to every external agent of the account and
# assistant.liquid renders it as the "# Clinic" block, after the shared rules of the installation and before the agent's own
# instructions.
#
# It lives in internal_attributes, which no clinic-facing screen or API reads or writes: only the platform team edits it (the
# account form of the super admin, or the onelink:captain:apply_prompt_pack rake).
#
# The text is shared by every agent of the clinic, so it may not mention a tool or a skill (a tool:// link would bind that tool
# to every agent) and may link only contact fields ([ИИН пациента](field://contact.identifier)), the scope every agent can read.
module AccountCaptainClinicContext
  extend ActiveSupport::Concern

  CAPTAIN_CLINIC_CONTEXT_KEY = 'captain_clinic_context'.freeze
  CAPTAIN_CLINIC_CONTEXT_MAX_LENGTH = 6000
  CAPTAIN_CLINIC_CONTEXT_FORBIDDEN_LINK = %r{(?:tool|skill)://}i
  CAPTAIN_CLINIC_CONTEXT_FIELD_LINK = %r{field://([^)\s]*)}i
  CAPTAIN_CLINIC_CONTEXT_FIELD_ID = /\Acontact\.\S+\z/

  included do
    validate :validate_captain_clinic_context, if: -> { @captain_clinic_context_changed }
  end

  class_methods do
    # The text as it is stored: Windows line ends become "\n" and the blank edges go.
    def normalize_captain_clinic_context(value)
      value.to_s.gsub(/\r\n?/, "\n").strip
    end

    # What is wrong with a clinic context, as [error, options] pairs for errors.add; empty when it may be saved.
    #   Account.captain_clinic_context_errors('… [@Запись](tool://create_appointment) …') # => [[:tool_link, {}]]
    def captain_clinic_context_errors(value)
      text = normalize_captain_clinic_context(value)
      problems = []
      problems << [:too_long, { count: CAPTAIN_CLINIC_CONTEXT_MAX_LENGTH }] if text.length > CAPTAIN_CLINIC_CONTEXT_MAX_LENGTH
      problems << [:tool_link, {}] if text.match?(CAPTAIN_CLINIC_CONTEXT_FORBIDDEN_LINK)
      field_ids = text.scan(CAPTAIN_CLINIC_CONTEXT_FIELD_LINK).flatten
      problems << [:field_link, {}] unless field_ids.all? { |field_id| field_id.match?(CAPTAIN_CLINIC_CONTEXT_FIELD_ID) }
      problems
    end
  end

  # The stored text, or an empty string when the clinic has none.
  def captain_clinic_context
    value = internal_attributes.to_h.stringify_keys[CAPTAIN_CLINIC_CONTEXT_KEY]
    value.is_a?(String) ? value.strip : ''
  end

  # A blank value removes the key; the other internal attributes stay as they are. The same text again changes nothing (the
  # account form posts the field with every save) and is not checked again.
  def captain_clinic_context=(value)
    text = self.class.normalize_captain_clinic_context(value)
    return if text == captain_clinic_context

    @captain_clinic_context_changed = true
    attributes = internal_attributes.to_h.deep_stringify_keys
    if text.present?
      attributes[CAPTAIN_CLINIC_CONTEXT_KEY] = text
    else
      attributes.delete(CAPTAIN_CLINIC_CONTEXT_KEY)
    end
    self.internal_attributes = attributes
  end

  private

  def validate_captain_clinic_context
    self.class.captain_clinic_context_errors(captain_clinic_context).each do |error, options|
      errors.add(:captain_clinic_context, error, **options)
    end
  end
end
