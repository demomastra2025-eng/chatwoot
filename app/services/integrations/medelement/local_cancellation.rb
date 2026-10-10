# Owner decision (01.10.2026): MedElement has no "cancelled" status, so a OneLink cancellation of a
# MedElement-linked appointment either removes the reception there or stays local. The hook setting
# `remove_reception_on_cancel` (default off) picks the mode. In the local-only mode the appointment keeps
# a marker so synchronization, reminders and the UI know the reception is still alive in MedElement.
module Integrations::Medelement::LocalCancellation
  MARKER_KEY = 'medelement_local_cancellation'.freeze
  MODE_LOCAL_ONLY = 'local_only'.freeze
  MODE_PROVIDER_REMOVAL = 'provider_removal'.freeze
  RECEPTION_PREFIX = 'medelement:reception:'.freeze
  PRESERVED_REASON = 'preserved_local_cancellation'.freeze
  REBOOKED_REASON = 'provider_rebooked_after_local_cancellation'.freeze

  module_function

  def remove_reception_on_cancel?(account_id)
    hook = Integrations::Hook.find_by(account_id: account_id, app_id: 'medelement')
    hook.present? && Integrations::Medelement::Configuration.new(hook: hook).remove_reception_on_cancel?
  end

  def local_only?(appointment)
    !remove_reception_on_cancel?(appointment.account_id)
  end

  def cancellation_mode(appointment, remove_reception_on_cancel: nil)
    return unless linked?(appointment)

    remove = remove_reception_on_cancel.nil? ? remove_reception_on_cancel?(appointment.account_id) : remove_reception_on_cancel
    remove ? MODE_PROVIDER_REMOVAL : MODE_LOCAL_ONLY
  end

  def linked?(appointment)
    appointment.source == Scheduling::Appointments::MutationGuard::PROVIDER_SOURCE ||
      reception_code(appointment).present? ||
      appointment.custom_attributes.to_h[Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY].present?
  end

  def marked?(record_or_attributes)
    attributes = record_or_attributes.respond_to?(:custom_attributes) ? record_or_attributes.custom_attributes : record_or_attributes
    attributes.to_h[MARKER_KEY].present?
  end

  # A local status change cannot free a reception still held by the provider. This also protects
  # older linked cancellations without a marker until an authoritative removal is observed.
  def provider_occupied?(appointment)
    return false unless %i[source custom_attributes external_ref].all? { |key| appointment.respond_to?(key) }
    return false unless linked?(appointment)
    return true if marked?(appointment)

    !Integrations::Medelement::AppointmentProviderStatus.cancellation_confirmed?(appointment)
  end

  def reception_code(appointment)
    attributes = appointment.custom_attributes.to_h
    return attributes['medelement_reception_code'].to_s if attributes['medelement_reception_code'].present?
    return unless appointment.external_ref.to_s.start_with?(RECEPTION_PREFIX)

    appointment.external_ref.delete_prefix(RECEPTION_PREFIX).presence
  end

  # Identifiers and times only: no patient data is copied into the marker.
  def marker(appointment, actor, at: Time.current)
    {
      'at' => at.utc.iso8601,
      'actor' => actor_descriptor(actor),
      'reception_code' => reception_code(appointment),
      'provider_starts_at' => appointment.starts_at&.utc&.iso8601,
      'provider_ends_at' => appointment.ends_at&.utc&.iso8601,
      'previous_status' => appointment.status,
      'previous_payment_status' => appointment.payment_status
    }.compact
  end

  # MedElement moved the still-active reception to another start time: the patient was re-booked there.
  def rebooked?(appointment, provider_starts_at)
    snapshot = appointment.custom_attributes.to_h.dig(MARKER_KEY, 'provider_starts_at')
    return false if snapshot.blank? || provider_starts_at.blank?

    Time.iso8601(snapshot.to_s).to_i != provider_starts_at.to_i
  rescue ArgumentError
    false
  end

  def restored_payment_status(appointment)
    previous = appointment.custom_attributes.to_h.dig(MARKER_KEY, 'previous_payment_status').to_s
    return previous if previous.in?(Scheduling::Constants::PAYMENT_STATUSES) && previous != 'cancelled'

    'awaiting_payment'
  end

  def actor_descriptor(actor)
    return if actor.blank?

    { 'type' => actor.class.base_class.name, 'id' => actor.id }
  end
end
