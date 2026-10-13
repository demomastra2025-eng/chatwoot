# frozen_string_literal: true

# What an action is done to: the person a booking is for, the appointment a change or a cancellation is for.
#
# The guards of a run (Captain::Runtime::OperationGuard, Captain::Runtime::ToolWrapper) claim an action tool once per request and
# refuse the same tool with other arguments afterwards, because the first call may have reached the provider. Two calls that act on
# two different targets are two operations: one agent books a parent and a child, or cancels two appointments, in one message. The
# target is part of the claim; the same target with other arguments is refused as before.
module Captain::Runtime::OperationTarget
  APPOINTMENT_TOOLS = %w[update_appointment cancel_appointment].freeze
  PERSON_FIELDS = %i[first_name last_name middle_name birth_date iin].freeze

  module_function

  # nil when the call has no target of its own: the person of the conversation, or a tool that is claimed as a whole.
  def of(tool_name, arguments)
    arguments = arguments.to_h.deep_symbolize_keys
    case Captain::Runtime::ToolFailure.canonical_name(tool_name)
    when 'create_appointment' then person(arguments[:patient])
    when *APPOINTMENT_TOOLS then arguments[:appointment_id].presence&.to_s
    end
  rescue StandardError
    nil
  end

  # The patient parameter of a booking: the same words for the same person, whatever the case or the spaces.
  def person(patient)
    return unless patient.is_a?(Hash)

    fields = patient.deep_symbolize_keys.slice(*PERSON_FIELDS).transform_values { |value| value.to_s.squish.downcase }.compact_blank
    Digest::SHA256.hexdigest(JSON.generate(fields.sort.to_h)) if fields.present?
  end
end
