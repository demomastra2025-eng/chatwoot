# frozen_string_literal: true

require Rails.root.join('enterprise/lib/onelink/mcp/access_policy').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/auth_context').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/captain_tool_adapter').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/openapi_catalog').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/settings_payload').to_s

class Api::V1::Accounts::McpSettingsController < Api::V1::Accounts::BaseController
  before_action :authorize_account_update, only: [:update]

  def show
    render json: settings_payload
  end

  def update
    @current_account.mcp_access = Onelink::Mcp::AccessPolicy.normalize(permitted_mcp_access)
    @current_account.save!

    render json: settings_payload
  end

  private

  def authorize_account_update
    authorize @current_account, :update?
  end

  def settings_payload
    Onelink::Mcp::SettingsPayload.new(auth_context: mcp_auth_context).as_json
  end

  def mcp_auth_context
    @mcp_auth_context ||= Onelink::Mcp::AuthContext.from_controller(self)
  end

  def permitted_mcp_access
    params.require(:mcp_access).permit(
      :enabled,
      :max_risk_level,
      :require_confirmation_for_mutations,
      sources: %i[captain openapi_read openapi_write],
      allowed_groups: [],
      blocked_groups: [],
      allowed_tool_ids: [],
      blocked_tool_ids: [],
      allowed_openapi_operation_ids: [],
      blocked_openapi_operation_ids: []
    ).to_h
  end
end
