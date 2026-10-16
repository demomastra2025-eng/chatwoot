class Api::V1::Accounts::Telephony::WebphoneController < Api::V1::Accounts::Telephony::BaseController
  def create
    inbox = Current.account.inboxes.find_by(id: params[:inbox_id]) if params[:inbox_id].present?
    authorize inbox, :show? if inbox.present?

    render_payload(
      webphone_service.token_for(
        user: Current.user,
        inbox: inbox,
        client_instance_id: params[:client_instance_id],
        browser_instance_id: params[:browser_instance_id],
        lease_mode: params[:lease_mode]
      )
    )
  end

  def presence
    inbox = Current.account.inboxes.find_by(id: params[:inbox_id]) if params[:inbox_id].present?
    authorize inbox, :show? if inbox.present?

    render_payload(
      webphone_service.update_presence!(
        user: Current.user,
        registered: ActiveModel::Type::Boolean.new.cast(params.require(:registered)),
        inbox: inbox,
        registration_context: presence_params.to_h.merge(presence_failure_params.to_h)
      )
    )
  end

  def incoming
    inbox = Current.account.inboxes.find(params.require(:inbox_id))
    authorize inbox, :show?

    render_payload(
      webphone_service.report_browser_sip_incoming!(
        user: Current.user,
        inbox: inbox,
        params: incoming_params.to_h
      )
    )
  end

  def claim
    render_payload(
      Telephony::OperatorCallClaimService.new(
        account: Current.account,
        user: Current.user,
        call_ref: params.require(:call_ref)
      ).perform
    )
  end

  def answered
    render_payload(
      Telephony::OperatorCallAnsweredService.new(
        account: Current.account,
        user: Current.user,
        call_ref: params.require(:call_ref),
        answered_at: params[:answered_at]
      ).perform
    )
  end

  def reject
    render_payload(
      Telephony::OperatorCallRejectService.new(
        account: Current.account,
        user: Current.user,
        call_ref: params.require(:call_ref),
        status: params[:status],
        reason: params[:reason],
        ended_at: params[:ended_at]
      ).perform
    )
  end

  def channel_capacity
    inbox = Current.account.inboxes.find_by(id: params[:inbox_id]) if params[:inbox_id].present?
    authorize inbox, :show? if inbox.present?

    connection = resolve_wazo_connection(inbox)
    capacity = connection.present? ? Telephony::Wazo::ChannelCapacityService.new(connection: connection).snapshot : nil
    render_payload(
      capacity: capacity,
      transfer_targets: available_transfer_targets(inbox)
    )
  end

  def transfer
    inbox = Current.account.inboxes.find_by(id: params[:inbox_id]) if params[:inbox_id].present?
    authorize inbox, :show? if inbox.present?

    result = Telephony::Wazo::CallTransferService.new(account: Current.account).transfer!(
      initiator_call_id: params[:initiator_call_id],
      initiator_user_id: Current.user.id,
      customer_number: params[:customer_number],
      target_extension: params[:target_extension],
      target_user_id: params[:target_user_id],
      flow: params[:flow].presence || 'blind'
    )
    render_payload(result)
  end

  private

  def webphone_service
    @webphone_service ||= Telephony::WebphoneService.new(account: Current.account)
  end

  def resolve_wazo_connection(inbox)
    scope = Current.account.telephony_provider_connections.where(provider_kind: 'wazo', status: 'active')
    if inbox.present?
      binding = Telephony::NumberBinding.find_by(account_id: Current.account.id, inbox_id: inbox.id, provider: 'wazo')
      return binding.provider_connection if binding&.provider_connection.present?
    end
    scope.first
  end

  def available_transfer_targets(inbox)
    scope = Current.account.telephony_sip_profiles.includes(:user).where(status: 'active', enabled: true)
    scope = scope.where(inbox_id: inbox.id) if inbox.present?
    scope.filter_map do |profile|
      next if profile.internal_extension.blank? || profile.user_id == Current.user.id

      {
        user_id: profile.user_id,
        name: profile.user&.name.presence || "Ext #{profile.internal_extension}",
        internal_extension: profile.internal_extension
      }
    end
  end

  def incoming_params
    params.permit(
      :provider,
      :call_ref,
      :callRef,
      :call_sid,
      :callSid,
      :from,
      :from_number,
      :fromNumber,
      :to,
      :to_number,
      :toNumber,
      :session_key,
      :sessionKey,
      :sip_profile_id,
      :sipProfileId,
      :janus_session_id,
      :janusSessionId,
      :janus_handle_id,
      :janusHandleId,
      :janus_unique_id,
      :janusUniqueId,
      :janus_master_id,
      :janusMasterId,
      :internal_extension,
      :internalExtension,
      :sip_username,
      :sipUsername,
      :sip_host,
      :sipHost,
      :agent_aor,
      :agentAor,
      :registration_instance_id,
      :registrationInstanceId,
      :registration_config_version,
      :registrationConfigVersion
    )
  end

  def presence_params
    params.permit(
      :sip_profile_id,
      :sipProfileId,
      :account_id,
      :accountId,
      :inbox_id,
      :inboxId,
      :user_id,
      :userId,
      :profile_kind,
      :profileKind,
      :internal_extension,
      :internalExtension,
      :sip_username,
      :sipUsername,
      :sip_host,
      :sipHost,
      :agent_aor,
      :agentAor,
      :credentials_ref,
      :credentialsRef,
      :password_secret_ref,
      :passwordSecretRef,
      :availability_mode,
      :availabilityMode,
      :enabled,
      :status,
      :registration_config_version,
      :registrationConfigVersion,
      :registration_instance_id,
      :registrationInstanceId,
      :session_key,
      :sessionKey,
      :janus_session_id,
      :janusSessionId,
      :janus_handle_id,
      :janusHandleId,
      :janus_unique_id,
      :janusUniqueId,
      :janus_master_id,
      :janusMasterId,
      :presence_sequence,
      :presenceSequence
    )
  end

  # Registration failure diagnostics (Beeline) stay in their own permit list so the
  # reviewed presence permit list above is unchanged.
  def presence_failure_params
    params.permit(:registration_failure_code, :registrationFailureCode, :registration_failure_reason, :registrationFailureReason)
  end
end
