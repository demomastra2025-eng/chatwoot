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
    scope = scope.where(auditable_type: params[:auditable_type]) if params[:auditable_type].present?
    scope = scope.where(action: params[:audit_action]) if params[:audit_action].present?
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
    scope
  end
end
