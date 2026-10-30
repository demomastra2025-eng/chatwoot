# frozen_string_literal: true

class Api::V1::OwnerFinance::BaseController < Api::BaseController
  skip_before_action :enforce_super_admin_impersonation_scope!, raise: false
  before_action :authorize_owner_finance!

  private

  def authorize_owner_finance!
    actor = Current.user || current_user
    return if OwnerFinance::AccessPolicy.allowed?(actor, impersonation_context: @super_admin_impersonation)

    head :not_found
  end
end
