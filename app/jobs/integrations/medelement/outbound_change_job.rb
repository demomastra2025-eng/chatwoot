class Integrations::Medelement::OutboundChangeJob < ApplicationJob
  class BusyError < StandardError; end

  queue_as :medelement_provider_commands

  retry_on BusyError, wait: 30.seconds, attempts: 20
  discard_on ActiveRecord::RecordNotFound

  # rubocop:disable Metrics/ParameterLists
  def perform(entity_type:, entity_id:, event_name:, change: {}, actor_id: nil, event_key: nil)
    Integrations::Medelement::OutboundChangeService.new(
      entity_type: entity_type,
      entity_id: entity_id,
      event_name: event_name,
      change: change,
      actor_id: actor_id,
      event_key: event_key
    ).perform
  rescue Scheduling::Error => e
    raise BusyError, e.message if e.code == 'MEDELEMENT_COMMAND_IN_PROGRESS'

    raise
  end
  # rubocop:enable Metrics/ParameterLists
end
