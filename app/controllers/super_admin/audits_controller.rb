# frozen_string_literal: true

class SuperAdmin::AuditsController < SuperAdmin::ApplicationController
  def index
    @auditable_types = fetch_auditable_types
    @audits = filter_audits.page(params[:page]).per(25)
  end

  def show
    @audit = Audited::Audit.find(params[:id])
  end

  private

  def fetch_auditable_types
    Audited::Audit.distinct.pluck(:auditable_type).compact.sort
  rescue StandardError
    []
  end

  def filter_audits
    scope = Audited::Audit.order(created_at: :desc)
    scope = filter_by_model(scope)
    filter_by_account(scope)
  end

  def filter_by_model(scope)
    scope = scope.where(auditable_type: params[:auditable_type]) if params[:auditable_type].present?
    scope = scope.where(action: params[:audit_action]) if params[:audit_action].present?
    params[:user_id].present? ? scope.where(user_id: params[:user_id]) : scope
  end

  def filter_by_account(scope)
    return scope if params[:account_id].blank?

    acc_id = params[:account_id].to_i
    scope.where(
      "(auditable_type = 'Account' AND auditable_id = :acc_id) OR (associated_type = 'Account' AND associated_id = :acc_id)",
      acc_id: acc_id
    )
  end
end
