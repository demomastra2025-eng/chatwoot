class Api::V1::Accounts::Telephony::WebphoneController < Api::V1::Accounts::Telephony::BaseController
  def create
    inbox = Current.account.inboxes.find_by(id: params[:inbox_id]) if params[:inbox_id].present?
    authorize inbox, :show? if inbox.present?

    render_payload(webphone_service.token_for(user: Current.user, inbox: inbox))
  end

  def presence
    inbox = Current.account.inboxes.find_by(id: params[:inbox_id]) if params[:inbox_id].present?
    authorize inbox, :show? if inbox.present?

    render_payload(
      webphone_service.update_presence!(
        user: Current.user,
        registered: ActiveModel::Type::Boolean.new.cast(params.require(:registered)),
        inbox: inbox,
        registration_context: presence_params.to_h
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

  private

  def webphone_service
    @webphone_service ||= Telephony::WebphoneService.new(account: Current.account)
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
end
