# frozen_string_literal: true

class Telephony::Wazo::CallTransferService
  FLOWS = %w[blind attended].freeze

  def initialize(account:, client: nil, default_context: ENV.fetch('TELEPHONY_WAZO_SIP_CONTEXT', nil))
    @account = account
    @client = client
    @default_context = default_context.to_s.strip
  end

  def transfer!(initiator_call_id:, transferred_call_id: nil, target_extension: nil, target_user_id: nil, flow: 'blind', timeout: 30, variables: {})
    validate_flow!(flow)
    exten, context = resolve_destination!(target_extension: target_extension, target_user_id: target_user_id)
    resolved_transferred_call = transferred_call_id.presence || resolve_transferred_call_id!(initiator_call_id)

    response = client.initiate_transfer(
      transferred_call: resolved_transferred_call,
      initiator_call: initiator_call_id,
      context: context,
      exten: exten,
      flow: flow,
      variables: variables,
      timeout: timeout
    )

    {
      transfer_id: response['id'],
      status: response['status'] || 'initiated',
      flow: flow,
      initiator_call_id: initiator_call_id,
      transferred_call_id: resolved_transferred_call,
      target_extension: exten,
      context: context
    }
  end

  def complete!(transfer_id:)
    client.complete_transfer(transfer_id)
    { transfer_id: transfer_id, status: 'completed' }
  end

  def cancel!(transfer_id:)
    client.cancel_transfer(transfer_id)
    { transfer_id: transfer_id, status: 'cancelled' }
  end

  private

  attr_reader :account, :default_context

  def client
    @client ||= Telephony::Wazo::ApiClient.new
  end

  def validate_flow!(flow)
    return if FLOWS.include?(flow.to_s)

    raise Telephony::Error.new(
      code: 'WAZO_TRANSFER_FLOW_INVALID',
      message: "Unsupported Wazo transfer flow: #{flow}",
      status: :unprocessable_content
    )
  end

  def resolve_destination!(target_extension:, target_user_id:)
    if target_user_id.present?
      profile = account.telephony_sip_profiles.where(user_id: target_user_id, status: 'active', enabled: true).first
      unless profile&.internal_extension.present?
        raise Telephony::Error.new(
          code: 'WAZO_TRANSFER_TARGET_NOT_FOUND',
          message: 'Target operator does not have an active SIP extension',
          status: :not_found
        )
      end
      context = profile.metadata.to_h['wazo_sip_context'].presence || default_context
      return [profile.internal_extension.to_s, require_context!(context)]
    end

    exten = target_extension.to_s.strip
    if exten.blank?
      raise Telephony::Error.new(
        code: 'WAZO_TRANSFER_TARGET_REQUIRED',
        message: 'Transfer requires either target_extension or target_user_id',
        status: :unprocessable_content
      )
    end

    [exten, require_context!(default_context)]
  end

  def require_context!(context)
    return context if context.present?

    raise Telephony::Error.new(
      code: 'WAZO_SIP_CONTEXT_NOT_CONFIGURED',
      message: 'Wazo SIP context is required for call transfer',
      status: :service_unavailable
    )
  end

  def resolve_transferred_call_id!(initiator_call_id)
    call = client.active_call(initiator_call_id)
    peer_call_id = call['talking_to'].to_h.keys.first
    return peer_call_id if peer_call_id.present?

    raise Telephony::Error.new(
      code: 'WAZO_TRANSFERRED_CALL_NOT_FOUND',
      message: 'Active call has no bridged peer channel to transfer',
      status: :conflict
    )
  end
end
