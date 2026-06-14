# frozen_string_literal: true

class Api::V1::Accounts::Telephony::VirtualPbxChannelsController < Api::V1::Accounts::Telephony::BaseController
  before_action :check_admin_authorization?

  def show
    render_payload(provisioning_service.show(inbox_id: params.require(:id), include_diagnostics: include_diagnostics?))
  end

  def templates
    render_payload(provisioning_service.templates)
  end

  def status
    render_payload(provisioning_service.status(inbox_id: params.require(:id), include_diagnostics: include_diagnostics?))
  end

  def create
    render_payload(
      provisioning_service.create_channel(
        virtual_pbx_payload,
        dry_run: dry_run?,
        remote_commit: remote_commit?,
        include_diagnostics: include_diagnostics?
      )
    )
  end

  def update
    render_payload(
      provisioning_service.update_channel(
        inbox_id: params.require(:id),
        payload: virtual_pbx_payload,
        dry_run: dry_run?,
        remote_commit: remote_commit?,
        include_diagnostics: include_diagnostics?
      )
    )
  end

  def destroy
    render_payload(
      provisioning_service.delete_channel(
        inbox_id: params.require(:id),
        confirm: parse_boolean(params[:confirm], default: false),
        dry_run: dry_run?,
        remote_commit: remote_commit?,
        include_diagnostics: include_diagnostics?
      )
    )
  end

  def readiness_check
    render_payload(provisioning_service.readiness_check(inbox_id: params.require(:id), include_diagnostics: include_diagnostics?))
  end

  def provisioning_plan
    render_payload(
      provisioning_service.provisioning_plan(
        inbox_id: params.require(:id),
        operation: params[:operation].presence || 'update',
        include_diagnostics: include_diagnostics?
      )
    )
  end

  def provision
    render_payload(
      provisioning_service.provision(
        inbox_id: params.require(:id),
        remote_commit: remote_commit?,
        include_diagnostics: include_diagnostics?
      )
    )
  end

  def reconcile
    render_payload(provisioning_service.reconcile(inbox_id: params.require(:id), include_diagnostics: include_diagnostics?))
  end

  def provisioning_runs
    render_payload(provisioning_service.provisioning_runs(inbox_id: params.require(:id)))
  end

  private

  def provisioning_service
    @provisioning_service ||= Telephony::VirtualPbx::ProvisioningService.new(account: Current.account, current_user: Current.user)
  end

  def virtual_pbx_payload
    payload_source.permit(
      :provider_kind,
      :channel_name,
      :name,
      :display_phone_number,
      :phone_number,
      :provider_account_number,
      :sipuni_account_number,
      :account_number,
      :ingress_number,
      :sipuni_ingress_number,
      :provider_number,
      :fonoster_tel_url,
      :tel_url,
      connection: %i[host port transport username password send_register],
      routing: %i[mode fallback_mode ai_enabled operator_agent_aor],
      metadata: %i[environment source notes],
      profiles: %i[user_id internal_extension sip_username sip_password enabled availability_mode]
    ).to_h
  end

  def payload_source
    params[:virtual_pbx_channel].presence || params
  end

  def dry_run?
    parse_boolean(params[:dry_run], default: true)
  end

  def remote_commit?
    parse_boolean(params[:remote_commit], default: false)
  end

  def include_diagnostics?
    parse_boolean(params[:include_diagnostics], default: false)
  end
end
