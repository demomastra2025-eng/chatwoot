# frozen_string_literal: true

class Api::V1::OwnerFinance::BaseController < Api::BaseController
  skip_before_action :authenticate_access_token!, raise: false
  skip_before_action :validate_bot_access_token!, raise: false
  skip_before_action :authenticate_user!, raise: false
  skip_before_action :ensure_active_auth_session!, raise: false
  skip_before_action :enforce_super_admin_impersonation_scope!, raise: false
  skip_before_action :mark_interactive_ui_request, raise: false
  before_action :authorize_owner_finance!

  private

  def authorize_owner_finance!
    actor = resolve_owner_finance_actor
    return head(:unauthorized) if actor.nil?

    detect_impersonation_context!(actor)
    if OwnerFinance::AccessPolicy.allowed?(actor, impersonation_context: @super_admin_impersonation)
      Current.user ||= actor if actor.is_a?(User)
      return
    end

    head :not_found
  end

  def detect_impersonation_context!(actor)
    return if @super_admin_impersonation.present? || !actor.is_a?(User)

    client_id = current_auth_client_id
    return unless client_id.to_s.start_with?(SuperAdmin::ImpersonationService::CLIENT_PREFIX)

    @super_admin_impersonation = SuperAdmin::ImpersonationService.context_for_request(
      client_id, target_user_id: actor.id
    ) || { 'impersonated' => true }
  end

  def resolve_owner_finance_actor
    direct_actor || warden_or_session_actor
  end

  def direct_actor
    Current.user ||
      (defined?(current_user) && current_user) ||
      (defined?(current_super_admin) && current_super_admin)
  end

  def warden_or_session_actor
    warden_actor(:super_admin) ||
      warden_actor(:user) ||
      session_warden_actor('warden.user.super_admin.key') ||
      session_warden_actor('warden.user.user.key')
  end

  def warden_actor(scope)
    request.env['warden']&.user(scope)
  rescue StandardError
    nil
  end

  def session_warden_actor(key)
    raw = request.session[key]
    id = raw.is_a?(Array) ? raw.dig(0, 0) : nil
    id.present? ? User.find_by(id: id) : nil
  rescue StandardError
    nil
  end
end
