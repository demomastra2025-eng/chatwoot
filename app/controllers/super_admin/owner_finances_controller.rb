# frozen_string_literal: true

class SuperAdmin::OwnerFinancesController < SuperAdmin::ApplicationController
  before_action :authorize_owner_finance!

  def show; end

  private

  def authorize_owner_finance!
    return if OwnerFinance::AccessPolicy.allowed?(current_super_admin)

    head :not_found
  end
end
