class Integrations::Medelement::OutboundChangeJob < ApplicationJob
  class BusyError < StandardError; end
  PAYLOAD_VERSION = 2

  queue_as :medelement_provider_commands

  retry_on BusyError, wait: 30.seconds, attempts: 20
  discard_on ActiveRecord::RecordNotFound

  # rubocop:disable Metrics/ParameterLists
  def perform(entity_type:, entity_id:, event_name:, change: {}, actor_id: nil, event_key: nil)
    account_id = account_binding(change)
    attributes = {
      entity_type: entity_type,
      entity_id: entity_id,
      event_name: event_name,
      change: service_change(change),
      account_id: account_id,
      actor_id: actor_id,
      event_key: event_key
    }
    actor_descriptor = change.to_h.with_indifferent_access[:actor_descriptor]
    attributes[:actor_descriptor] = actor_descriptor if actor_descriptor.present?
    Integrations::Medelement::OutboundChangeService.new(**attributes).perform
  rescue Scheduling::Error => e
    raise BusyError, e.message if e.code == 'MEDELEMENT_COMMAND_IN_PROGRESS'

    raise
  end

  private

  def account_binding(change)
    attributes = change.to_h.with_indifferent_access
    return if legacy_payload?(attributes)
    return attributes[:account_id] if current_payload?(attributes)

    raise ArgumentError, 'Medelement outbound payload has invalid account binding'
  end

  def service_change(change)
    change.to_h.with_indifferent_access.except(:account_id, :payload_version, :actor_descriptor)
  end

  def legacy_payload?(attributes)
    !attributes.key?(:account_id) && !attributes.key?(:payload_version)
  end

  def current_payload?(attributes)
    attributes.key?(:account_id) && attributes.key?(:payload_version) &&
      attributes[:payload_version].is_a?(Integer) && attributes[:payload_version] == PAYLOAD_VERSION &&
      attributes[:account_id].is_a?(Integer) && attributes[:account_id].positive?
  end
  # rubocop:enable Metrics/ParameterLists
end
