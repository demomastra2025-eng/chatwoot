# frozen_string_literal: true

# An action on the accounts that were ticked in the account list (SuperAdmin::BulkAccounts): apply the plan and its
# modules, extend the trial, block, unblock, link to an organization.
#
#   GET  /super_admin/account_bulk_actions/new?bulk_action=suspend&account_ids[]=1&account_ids[]=2
#        the confirmation page: how many accounts and what will change in each (nothing is written)
#   POST /super_admin/account_bulk_actions
#        runs it, one account at a time, and goes back to the list with a summary (done, skipped and why)
#
# An action that needs a setting (the modules, the organization) shows the setting first, and the summary of changes only
# after it is chosen (`chosen=1`). At most SuperAdmin::BulkAccounts::LIMIT accounts a time; a longer list is refused whole.
# Every account that is changed leaves its own entry in the audit log.
class SuperAdmin::AccountBulkActionsController < SuperAdmin::ApplicationController
  # The list the operator came from (its filters and page), so the way back and «Отмена» keep them
  BACK_FORMAT = %r{\A/super_admin/accounts(\?\S*)?\z}
  BACK_LENGTH = 500

  before_action :load_bulk

  def new
    @preview = @bulk.preview if @bulk.ready?
  end

  def create
    return redirect_to(back_path, alert: flash_text(:not_ready)) unless @bulk.ready?

    result = @bulk.apply
    flash_key = result.done.positive? && result.skipped[:failed].zero? && result.skipped[:out_of_time].zero? ? :notice : :alert
    redirect_to back_path, flash_key => result_text(result)
  end

  private

  def load_bulk
    ids = SuperAdmin::BulkAccounts.parse_ids(params[:account_ids])
    return refuse(:malformed) if ids.nil?

    @bulk = SuperAdmin::BulkAccounts.new(action: bulk_action, ids: ids, options: bulk_options, actor: current_super_admin, request: request)
    return refuse(:unknown_action) unless @bulk.action_known?
    return refuse(:none_selected) if @bulk.empty?

    refuse(:too_many, count: SuperAdmin::BulkAccounts::LIMIT) if @bulk.too_many?
  end

  def bulk_action
    params[:bulk_action].is_a?(String) ? params[:bulk_action] : ''
  end

  # What the request carries for the actions that ask for a setting
  def bulk_options
    { chosen: params[:chosen], modules: params[:modules], organization_id: params[:organization_id] }
  end

  def refuse(reason, **)
    redirect_to back_path, alert: flash_text(reason, **)
  end

  def flash_text(key, **)
    I18n.t("super_admin.bulk.flashes.#{key}", **)
  end

  # The list of accounts the request came from, with its filters and page. The address is built again from the query of the
  # one that was sent, so only the list of accounts can come out of it: a foreign address or another page is not followed.
  def back_path
    raw = params[:back]
    return super_admin_accounts_path unless raw.is_a?(String) && raw.length <= BACK_LENGTH && raw.match?(BACK_FORMAT)

    query = URI.parse(raw).query
    query.present? ? super_admin_accounts_path(Rack::Utils.parse_nested_query(query)) : super_admin_accounts_path
  rescue URI::InvalidURIError, Rack::QueryParser::ParameterTypeError, Rack::QueryParser::InvalidParameterError
    super_admin_accounts_path
  end
  helper_method :back_path

  # «Заблокировать: успешно 12, пропущено 3 (уже заблокирован — 2; аккаунт на удалении — 1).»
  def result_text(result)
    reasons = result.skipped.map { |reason, count| I18n.t('super_admin.bulk.result.reason_item', reason: reason_text(reason).downcase, count: count) }
    list = reasons.any? ? I18n.t('super_admin.bulk.result.reasons', list: reasons.join('; ')) : ''
    I18n.t('super_admin.bulk.result.summary', action: I18n.t("super_admin.bulk.actions.#{bulk_action}"),
                                              done: result.done, skipped: result.skipped_total, reasons: list)
  end

  def reason_text(reason)
    I18n.t("super_admin.bulk.reasons.#{reason}")
  end
end
