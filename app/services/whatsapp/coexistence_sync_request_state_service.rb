class Whatsapp::CoexistenceSyncRequestStateService
  TERMINAL_REQUEST_STATES = %w[completed manual_recovery_required].freeze

  def initialize(channel, generation:)
    @channel = channel
    @generation = generation
  end

  def prepare(sync_type, keys)
    @channel.with_lock do
      config, sync = locked_config_and_sync
      next false unless generation_matches?(sync)
      next false if Whatsapp::CoexistenceSyncService.terminal_state?(sync)
      next false if request_already_persisted?(sync, keys)

      raise_claimed_request!(sync_type) if request_claimed?(sync, keys)
      persist(config, sync.merge(keys[:state] => 'requesting', keys[:started_at] => Time.current.iso8601))
      true
    end
  end

  def persist_accepted(sync_type, keys, response)
    request_id, accepted = response_identity(response)
    result = @channel.with_lock do
      config, sync = locked_config_and_sync
      next :stale unless generation_matches?(sync)

      resolve_response(config, sync, keys, request_id, accepted)
    end
    raise_unknown_response!(sync_type) if result == :outcome_unknown

    result
  end

  private

  def resolve_response(config, sync, keys, request_id, accepted)
    attributes = request_id_attributes(sync, keys, request_id)
    return persist_resolved_identity(config, sync, attributes) if request_resolved?(sync, keys)
    return persist_unknown_outcome(config, sync, keys) unless accepted

    persist_requested(config, sync, keys, attributes)
  end

  def persist_resolved_identity(config, sync, attributes)
    persist(config, sync.merge(attributes)) if attributes.present?
    :resolved
  end

  def persist_unknown_outcome(config, sync, keys)
    persist(config, sync.merge(keys[:state] => 'outcome_unknown'))
    :outcome_unknown
  end

  def persist_requested(config, sync, keys, attributes)
    attributes[keys[:state]] = 'requested'
    attributes[keys[:requested_at]] = Time.current.iso8601
    persist(config, sync.merge(attributes))
    :requested
  end

  def response_identity(response)
    response = response.to_h.with_indifferent_access
    request_id = response[:request_id] || response[:id]
    [request_id, response[:success] == true || request_id.present?]
  end

  def request_id_attributes(sync, keys, request_id)
    return {} if request_id.blank? || sync[keys[:id]].present?

    { keys[:id] => request_id }
  end

  def request_resolved?(sync, keys)
    Whatsapp::CoexistenceSyncService.terminal_state?(sync) || TERMINAL_REQUEST_STATES.include?(sync[keys[:state]])
  end

  def request_already_persisted?(sync, keys)
    sync[keys[:id]].present? || %w[requested completed].include?(sync[keys[:state]])
  end

  def request_claimed?(sync, keys)
    %w[requesting outcome_unknown].include?(sync[keys[:state]])
  end

  def raise_claimed_request!(sync_type)
    raise Whatsapp::CoexistenceSyncService::RequestAlreadyClaimedError,
          "Previous #{sync_type} request is already claimed; refusing a duplicate one-time request"
  end

  def raise_unknown_response!(sync_type)
    raise Whatsapp::CoexistenceSyncService::RequestOutcomeUnknownError,
          "Meta returned an ambiguous response for #{sync_type} synchronization"
  end

  def locked_config_and_sync
    config = @channel.reload.provider_config.deep_dup
    [config, config['coexistence_sync'].to_h]
  end

  def persist(config, sync)
    config['coexistence_sync'] = sync
    @channel.persist_provider_config_state!(config)
  end

  def generation_matches?(sync)
    @generation.present? && sync.to_h['generation'].to_s == @generation.to_s
  end
end
