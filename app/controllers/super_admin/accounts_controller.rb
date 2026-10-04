# rubocop:disable Metrics/ClassLength
class SuperAdmin::AccountsController < SuperAdmin::ApplicationController
  STORAGE_GB_IN_BYTES = 1.gigabyte

  # Overwrite any of the RESTful controller actions to implement custom behavior
  # For example, you may want to send an email after a foo is updated.
  #
  # def update
  #   super
  #   send_foo_updated_email(requested_resource)
  # end

  # Override this method to specify custom lookup behavior.
  # This will be used to set the resource for the `show`, `edit`, and `update`
  # actions.
  #
  # def find_resource(param)
  #   Foo.find_by!(slug: param)
  # end

  # The result of this lookup will be available as `requested_resource`

  # Override this if you have certain roles that require a subset
  # this will be used to set the records shown on the `index` action.
  #
  # def scoped_resource
  #   if current_user.super_admin?
  #     resource_class
  #   else
  #     resource_class.with_less_stuff
  #   end
  # end

  # Override `resource_params` if you want to transform the submitted
  # data before it's persisted. For example, the following would turn all
  # empty values into nil values. It uses other APIs such as `resource_class`
  # and `dashboard`:
  #
  def resource_params
    permitted_params = super
    permitted_params[:limits] = normalize_limits(permitted_params[:limits])
    merge_selected_feature_flags!(permitted_params)
    merge_limit_counter_user_exclusions!(permitted_params)
    merge_plan_type!(permitted_params)
    permitted_params
  end

  # See https://administrate-prototype.herokuapp.com/customizing_controller_actions
  # for more information

  def seed
    Internal::SeedAccountJob.perform_later(requested_resource)
    redirect_back(fallback_location: [namespace, requested_resource], notice: I18n.t('super_admin.accounts.flashes.demo_started'))
  end

  def reset_cache
    requested_resource.reset_cache_keys
    redirect_to_account(notice: I18n.t('super_admin.accounts.flashes.cache_reset'))
  end

  def reset_captain_responses_usage
    if requested_resource.reset_response_usage
      redirect_to_account(notice: I18n.t('super_admin.accounts.flashes.response_usage_reset'))
    else
      redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.response_usage_reset_failed'))
    end
  end

  def reset_captain_tokens_usage
    if requested_resource.reset_token_usage
      redirect_to_account(notice: I18n.t('super_admin.accounts.flashes.token_usage_reset'))
    else
      redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.token_usage_reset_failed'))
    end
  end

  def reset_email_usage
    requested_resource.reset_email_sent_count
    redirect_to_account(notice: I18n.t('super_admin.accounts.flashes.email_usage_reset'))
  end

  # Extends a running (or ended) trial. Putting an account that is not on a trial onto one is an explicit
  # decision: it needs `start=true`, which only the dedicated "start trial" button sends.
  def extend_trial
    audit_action = apply_trial_extension
    return redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.not_trial')) unless audit_action

    record_super_admin_audit(audit_action, 'trial_expires_at' => requested_resource.custom_attributes['trial_expires_at'])
    redirect_to_account(notice: I18n.t('super_admin.accounts.flashes.extend_success'))
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin] Trial update failed for account #{requested_resource.id}: #{e.class.name}")
    redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.trial_operation_failed'))
  end

  def expire_trial
    unless requested_resource.trial? && requested_resource.trial_snapshot?
      return redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.expire_requires_managed'))
    end

    return redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.trial_operation_failed')) unless requested_resource.expire_trial!

    record_super_admin_audit('expire_trial', 'trial_expired_at' => requested_resource.custom_attributes['trial_expired_at'])
    redirect_to_account(notice: I18n.t('super_admin.accounts.flashes.expire_success'))
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin] Trial expiry failed for account #{requested_resource.id}: #{e.class.name}")
    redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.trial_operation_failed'))
  end

  def impersonate
    target_user = requested_resource.administrators.first || requested_resource.users.first
    if target_user.present?
      grant = SuperAdmin::ImpersonationService.issue_grant!(
        actor: current_super_admin, account: requested_resource, target_user: target_user
      )
      record_super_admin_audit(
        'impersonate',
        'impersonated_user_id' => target_user.id,
        'impersonated_email' => target_user.email,
        'impersonation_session_id' => grant.client_id,
        'impersonation_grant_id' => grant.grant_id
      )
      redirect_to target_user.generate_sso_link_with_impersonation(sso_auth_token: grant.token), allow_other_host: true
    else
      redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.no_users_to_impersonate'))
    end
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/BlockLength
  def export
    require 'csv'

    accounts = Account.includes(:users, :inboxes)

    csv_data = CSV.generate(headers: true) do |csv|
      csv << [
        *I18n.t('super_admin.accounts.csv.headers')
      ]

      accounts.find_each do |acc|
        plan = acc.custom_attributes&.dig('plan_type').presence || 'custom'
        trial_status = if plan != 'trial'
                         I18n.t('super_admin.accounts.csv.no_trial')
                       elsif acc.trial_active?
                         I18n.t('super_admin.accounts.csv.active')
                       else
                         I18n.t('super_admin.accounts.csv.expired')
                       end

        trial_exp = if acc.custom_attributes&.dig('trial_expires_at').present?
                      begin
                        Time.zone.parse(acc.custom_attributes['trial_expires_at'].to_s).strftime('%d.%m.%Y %H:%M')
                      rescue StandardError
                        '-'
                      end
                    else
                      '-'
                    end

        storage_bytes = acc.limits&.[]('storage_bytes')
        limit_gb = storage_bytes.present? ? (storage_bytes.to_f / 1.gigabyte).round(1) : I18n.t('super_admin.accounts.csv.unlimited')
        # The breakdown is cached and refreshed hourly for every account, so the export does not have to scan
        # the disk and run a dozen queries per account inside one web request.
        used_mb = (acc.storage_breakdown[:total].to_f / 1.megabyte).round(2)

        csv << [
          acc.id,
          csv_safe(acc.name),
          csv_safe(plan.titleize),
          trial_status,
          trial_exp,
          acc.users.size,
          acc.inboxes.size,
          used_mb,
          limit_gb,
          acc.status,
          acc.created_at.strftime('%d.%m.%Y %H:%M')
        ]
      end
    end

    filename = "onelink-accounts-#{Time.current.strftime('%Y%m%d_%H%M%S')}.csv"
    send_data "\uFEFF#{csv_data}", filename: filename, type: 'text/csv; charset=utf-8; header=present', disposition: 'attachment'
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/BlockLength

  def destroy
    account = Account.find(params[:id])

    DeleteObjectJob.perform_later(account) if account.present?
    redirect_back(fallback_location: [namespace, requested_resource], notice: I18n.t('super_admin.accounts.flashes.account_deletion_started'))
  end

  private

  def apply_trial_extension
    if requested_resource.trial? && requested_resource.trial_snapshot?
      requested_resource.extend_trial!(3)
      'extend_trial'
    elsif params[:start].present?
      requested_resource.activate_trial!(3)
      'start_trial'
    end
  end

  def normalize_limits(raw_limits)
    raw_limits.to_h.each_with_object({}) do |(key, value), normalized|
      next if value.blank?

      normalized[key] = normalize_limit_value(key, value)
    rescue ArgumentError, TypeError
      normalized[key] = value
    end
  end

  def normalize_limit_value(key, value)
    return gb_to_bytes(value) if key.to_s == 'storage_bytes'

    Integer(value, 10)
  end

  def gb_to_bytes(value)
    (BigDecimal(value.to_s) * STORAGE_GB_IN_BYTES).round(0).to_i
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def merge_plan_type!(permitted_params)
    return unless params[:account]&.key?(:plan_type)

    plan_type = params[:account][:plan_type].presence
    updated_custom_attributes = (permitted_params[:custom_attributes] || requested_resource.custom_attributes || {}).deep_dup

    if plan_type.present?
      updated_custom_attributes['plan_type'] = plan_type
      if plan_type == 'trial' && updated_custom_attributes['trial_expires_at'].blank?
        updated_custom_attributes['trial_expires_at'] = 3.days.from_now.iso8601
      end
    elsif params[:account][:plan_type] == ''
      updated_custom_attributes.delete('plan_type')
    end

    permitted_params[:custom_attributes] = updated_custom_attributes
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def merge_limit_counter_user_exclusions!(permitted_params)
    return unless params[:account]&.key?(:limit_counter_excluded_user_ids_raw)

    normalized_ids = normalize_limit_counter_excluded_user_ids(
      params[:account][:limit_counter_excluded_user_ids_raw]
    )
    updated_custom_attributes =
      (limit_counter_exclusion_custom_attributes(permitted_params) || {}).deep_dup

    if normalized_ids.present?
      updated_custom_attributes[
        Enterprise::Account::LIMIT_COUNTER_EXCLUDED_USER_IDS_KEY
      ] = normalized_ids
    else
      updated_custom_attributes.delete(
        Enterprise::Account::LIMIT_COUNTER_EXCLUDED_USER_IDS_KEY
      )
    end

    permitted_params.delete(:limit_counter_excluded_user_ids_raw)
    permitted_params[:custom_attributes] = updated_custom_attributes
  end

  def merge_selected_feature_flags!(permitted_params)
    submitted_features = submitted_feature_states
    return if submitted_features.empty?

    enabled_features = submitted_features.filter_map do |feature_name, enabled|
      feature_name.to_sym if enabled
    end
    permitted_params[:selected_feature_flags] = preserved_feature_flags(submitted_features.keys) + enabled_features
  end

  def submitted_feature_states
    raw_features = params[:enabled_features]
    return {} unless raw_features.respond_to?(:to_unsafe_h)

    boolean_type = ActiveModel::Type::Boolean.new
    raw_features.to_unsafe_h.each_with_object({}) do |(feature_name, enabled), features|
      feature_name = feature_name.to_s
      next unless feature_name.start_with?('feature_')

      normalized_name = feature_name.delete_prefix('feature_')
      next unless Featurable::FEATURE_NAMES.include?(normalized_name)

      features[normalized_name] = boolean_type.cast(enabled)
    end
  end

  def preserved_feature_flags(submitted_names)
    return [] unless action_name == 'update'

    requested_resource.selected_feature_flags.map(&:to_s).reject do |feature_name|
      submitted_names.include?(feature_name)
    end
  end

  def limit_counter_exclusion_custom_attributes(permitted_params)
    return requested_resource.custom_attributes if action_name == 'update'

    permitted_params[:custom_attributes]
  end

  def normalize_limit_counter_excluded_user_ids(value)
    raw_values = value.is_a?(String) ? value.split(/[,\s]+/) : value

    Array(raw_values)
      .filter_map do |candidate|
        Integer(candidate.to_s.strip, 10)
      rescue ArgumentError, TypeError
        nil
      end
      .select(&:positive?)
      .uniq
      .sort
  end

  CSV_FORMULA_PREFIXES = ['=', '+', '-', '@', "\t", "\r"].freeze

  # Account names are chosen by customers. A cell that starts with one of these characters would be run as a
  # formula when the export is opened in a spreadsheet, so it is stored as plain text.
  def csv_safe(value)
    text = value.to_s
    text.start_with?(*CSV_FORMULA_PREFIXES) ? "'#{text}" : value
  end

  # Operator actions that change an account or reach into it leave an explicit entry in the audit log.
  def record_super_admin_audit(action, changes = {})
    Audited::Audit.create!(
      auditable: requested_resource, associated: requested_resource, action: action, audited_changes: changes,
      user: current_super_admin, remote_address: request.remote_ip, request_uuid: request.request_id, comment: 'super_admin'
    )
  rescue StandardError => e
    Rails.logger.error("[SuperAdmin] Could not record audit '#{action}' for account #{requested_resource&.id}: #{e.class.name}: #{e.message}")
  end

  def redirect_to_account(notice: nil, alert: nil)
    options = { fallback_location: [namespace, requested_resource] }
    options[:notice] = notice if notice.present?
    options[:alert] = alert if alert.present?

    redirect_back(**options)
  end
end

SuperAdmin::AccountsController.prepend_mod_with('SuperAdmin::AccountsController')

# rubocop:enable Metrics/ClassLength
