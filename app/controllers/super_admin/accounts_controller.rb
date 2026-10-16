# rubocop:disable Metrics/ClassLength
class SuperAdmin::AccountsController < SuperAdmin::ApplicationController
  STORAGE_GB_IN_BYTES = 1.gigabyte
  OWNER_DECISION_AUDIT_ACTION = 'update_service_flags'.freeze
  # What a malformed value (an array or a string where the form sends a map) is parsed as
  MALFORMED = Object.new.freeze

  # A request that switches a function the screens never offer (a function no plan enables, one that must stay on, a
  # platform-internal one) is refused with nothing saved; see SuperAdmin::FeatureChangeGuard.
  before_action :reject_forbidden_feature_changes, only: %i[create update]

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
    permitted_params = fine_tuning_only_request? ? ActionController::Parameters.new.permit : super
    # The organization of the account is changed through SuperAdmin::OrganizationLinks (see #update), never by the
    # generic save: it would leave an unsigned «update» entry in the audit log next to the signed one.
    permitted_params.delete(:organization_id)
    # A request without `limits` (the «Тонкая настройка» switches of the card) must not wipe the limits of the clinic.
    permitted_params[:limits] = normalize_limits(permitted_params[:limits]) if permitted_params.key?(:limits)
    merge_selected_feature_flags!(permitted_params)
    merge_limit_counter_user_exclusions!(permitted_params)
    permitted_params
  end

  # See https://administrate-prototype.herokuapp.com/customizing_controller_actions
  # for more information

  # A new account gets the base plan (plus the optional `modules` param) right after it is saved. The limits the
  # operator typed into the form win over the plan; the plan only fills the blanks. `start_trial` starts a trial on
  # top of it.
  def create
    modules = requested_plan_modules
    return redirect_to(new_super_admin_account_path, alert: I18n.t('super_admin.accounts.flashes.plan_unknown_module')) if modules.nil?

    super do |account|
      yield(account) if block_given?
      apply_plan_to_new_account(account, modules)
      start_trial_for_new_account(account) if start_trial_requested?
    end
  end

  # The owner-decision switches of «Служебные» are saved with this update too; a change of one leaves an entry in the
  # audit log of the clinic.
  def update
    owner_changes = owner_decision_changes
    organization = submitted_organization
    super
    return unless response.redirect?

    record_owner_decision_audit(owner_changes) if owner_changes.any?
    save_submitted_organization(organization)
  end

  # The select of the «Организация» block of the card: links the account to the organization, moves it to another one
  # or, with «Без организации», unlinks it. The change and its entries in the audit log are SuperAdmin::OrganizationLinks'.
  def link_organization
    organization = submitted_organization
    return redirect_to([namespace, requested_resource], alert: organization_flash(:missing)) if organization.nil? || organization == :missing

    notice = change_organization(requested_resource, organization) || organization_flash(:unchanged)
    redirect_to [namespace, requested_resource], notice: notice
  end

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

  # Writes base + the chosen modules (`modules[]`; none = the base alone) into the account and audits it.
  def apply_plan
    modules = requested_plan_modules
    return redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.plan_unknown_module')) if modules.nil?

    account = requested_resource
    begin
      Accounts::ApplyPlan.new(account: account, modules: modules, actor: current_super_admin, request: request).call
    rescue StandardError => e
      Rails.logger.warn("[SuperAdmin] Plan apply failed for account #{account.id}: #{e.class.name}: #{e.message}")
      return redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.plan_apply_failed'))
    end
    redirect_to_account(notice: I18n.t('super_admin.accounts.flashes.plan_applied', plan: Accounts::Plans.plan_label(modules)))
  end

  # What applying the plan would change, as JSON (nothing is written): flags to switch on and off, limit changes
  # and notes. The clinic card asks for the same thing as an HTML fragment (`fragment=1`) and shows it before the
  # operator confirms.
  def plan_preview
    modules = requested_plan_modules
    return render(json: { error: I18n.t('super_admin.accounts.flashes.plan_unknown_module') }, status: :unprocessable_content) if modules.nil?

    diff = Accounts::ApplyPlan.new(account: requested_resource, modules: modules, actor: current_super_admin).preview
    if params[:fragment].present?
      render partial: 'super_admin/accounts/plan_preview', locals: { diff: diff }, formats: [:html]
    else
      render json: diff
    end
  end

  # The clinic's own channel switches: `overrides[channel]` is default (follow the platform), shown or hidden.
  # Channels that are not sent keep their switch. Leaves one entry in the audit log with what changed.
  def channel_overrides
    requested = submitted_map(:overrides)
    expected = submitted_map(:previous)
    return render_card_error(I18n.t('super_admin.accounts.flashes.channel_overrides_malformed')) if [requested, expected].include?(MALFORMED)

    changes = Accounts::ChannelOverrides.new(
      account: requested_resource, actor: current_super_admin, request: request
    ).apply(requested, expected)
    flash_key = changes.any? ? :channel_overrides_saved : :channel_overrides_unchanged
    redirect_to_account(notice: I18n.t("super_admin.accounts.flashes.#{flash_key}"))
  rescue Accounts::ChannelOverrides::InvalidOverrides
    redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.channel_overrides_invalid'))
  rescue Accounts::ChannelOverrides::StaleOverrides
    redirect_to_account(alert: I18n.t('super_admin.accounts.flashes.channel_overrides_stale'))
  end

  def impersonate
    target_user = impersonation_target_user
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

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def export
    require 'csv'

    accounts = Account.includes(:users, :inboxes)

    csv_data = CSV.generate(headers: true) do |csv|
      csv << [
        *I18n.t('super_admin.accounts.csv.headers')
      ]

      accounts.find_each do |acc|
        plan_state = SuperAdmin::AccountPlanState.new(acc)
        trial_status = case plan_state.trial_state
                       when :none then I18n.t('super_admin.accounts.csv.no_trial')
                       when :active then I18n.t('super_admin.accounts.csv.active')
                       else I18n.t('super_admin.accounts.csv.expired')
                       end

        # Times are Astana time (UTC+5)
        trial_exp = SuperAdmin::DisplayHelper.format_time(plan_state.trial_expires_at) || '-'

        storage_bytes = acc.limits&.[]('storage_bytes')
        limit_gb = storage_bytes.present? ? (storage_bytes.to_f / 1.gigabyte).round(1) : I18n.t('super_admin.accounts.csv.unlimited')
        # The breakdown is cached and refreshed hourly for every account, so the export does not have to scan
        # the disk and run a dozen queries per account inside one web request.
        measured_bytes = acc.storage_breakdown[:total]
        used_mb = measured_bytes.nil? ? nil : (measured_bytes.to_f / 1.megabyte).round(2)

        csv << [
          acc.id,
          csv_safe(acc.name),
          plan_state.label,
          trial_status,
          trial_exp,
          acc.users.size,
          acc.inboxes.size,
          used_mb,
          limit_gb,
          plan_state.status_label,
          SuperAdmin::DisplayHelper.format_time(acc.created_at)
        ]
      end
    end

    filename = "onelink-accounts-#{SuperAdmin::DisplayHelper.format_time(Time.current, '%Y%m%d_%H%M%S')}.csv"
    send_data "\uFEFF#{csv_data}", filename: filename, type: 'text/csv; charset=utf-8; header=present', disposition: 'attachment'
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def destroy
    account = Account.find(params[:id])

    DeleteObjectJob.perform_later(account) if account.present?
    redirect_back(fallback_location: [namespace, requested_resource], notice: I18n.t('super_admin.accounts.flashes.account_deletion_started'))
  end

  private

  # The «Тонкая настройка» form of the clinic card posts only the switches (`enabled_features`) and no `account` group.
  # Re-sending the name the page was drawn with would undo a rename made in another tab or by another administrator.
  def fine_tuning_only_request?
    action_name == 'update' && !params.key?(:account) && params[:enabled_features].present?
  end

  # What the organization select asked for (account[organization_id] of the edit form, organization_id of the card):
  # nil when the request does not carry it (the account keeps its organization), :none for «Без организации», :missing
  # for an organization that does not exist, or the Organization.
  def submitted_organization
    container = action_name == 'update' ? params[:account] : params
    return unless container.respond_to?(:key?) && container.key?(:organization_id)

    value = container[:organization_id]
    return :missing unless value.is_a?(String)
    return :none if value.strip.empty?

    Organization.find_by(id: value.strip) || :missing
  end

  # The edit form saves the organization after the account itself, and only when the account was saved
  def save_submitted_organization(organization)
    return if organization.nil?

    if organization == :missing
      flash[:alert] = organization_flash(:missing)
    elsif (message = change_organization(requested_resource, organization))
      flash[:notice] = [flash[:notice], message].compact_blank.join(' ')
    end
  end

  # Moves the account to the organization (:none unlinks it) through SuperAdmin::OrganizationLinks, which writes only the
  # foreign key and leaves the entries of the audit log on both sides with the super admin as the actor. The page this
  # request came from may be out of date, so the organization the account leaves is the one the links found under the
  # lock of the account row (the account card and the edit form may move an account from wherever it is). Returns what
  # to tell the operator, nil when the account was where it was asked to be.
  def change_organization(account, target)
    links = SuperAdmin::OrganizationLinks.new(actor: current_super_admin, request: request)
    if target == :none
      result = links.unlink(account: account)
      return unless result.changed?

      organization_flash(:unlinked, organization: result.previous.name)
    else
      result = links.link(account: account, organization: target)
      return unless result.changed?

      organization_flash(result.previous ? :moved : :linked, organization: target.name)
    end
  end

  def organization_flash(key, **)
    I18n.t("super_admin.accounts.flashes.organization_#{key}", **)
  end

  # The list can be narrowed to the accounts of one organization (`organization_id`, or `none` for the accounts that have
  # no organization); anything else asks for the whole list
  def organization_filter
    value = params[:organization_id]
    return unless value.is_a?(String)

    value = value.strip
    value if value == 'none' || value.match?(/\A\d{1,18}\z/)
  end

  def list_scope_params
    { organization_id: organization_filter }.compact
  end

  def filter_resources(resources, search_term:)
    filter = organization_filter
    resources = resources.where(organization_id: filter == 'none' ? nil : filter) if filter
    super(resources, search_term: search_term)
  end

  # The organization of every account of the page is read with one query
  def apply_collection_includes(relation)
    super.preload(:organization)
  end

  def apply_trial_extension
    if requested_resource.trial? && requested_resource.trial_snapshot?
      requested_resource.extend_trial!(Accounts::Plans.trial_days)
      'extend_trial'
    elsif params[:start].present?
      # A trial a super admin chose for a clinic that has a plan only lends it modules: its end leaves the limits alone
      requested_resource.activate_trial!(Accounts::Plans.trial_days, keep_limits: true)
      'start_trial'
    end
  end

  # The `modules` param as a list of known module keys; nil when it is malformed or names an unknown module.
  def requested_plan_modules
    raw = params[:modules]
    return [] if raw.blank?
    return nil unless raw.is_a?(Array) || raw.is_a?(String)

    Accounts::Plans.normalize_modules(raw)
  rescue ArgumentError
    nil
  end

  # nil when the param is absent, a Hash, or MALFORMED for anything that is not a map
  def submitted_map(name)
    raw = params[name]
    return if raw.nil?

    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : MALFORMED
  end

  # The clinic card again, with the message on top and the status 422 (nothing was saved)
  def render_card_error(message)
    flash.now[:alert] = message
    render :show, locals: { page: Administrate::Page::Show.new(dashboard, requested_resource) }, status: :unprocessable_content
  end

  # Runs before create and update: refuses a switch the clinic may not have changed (SuperAdmin::FeatureChangeGuard).
  # What the request changes is kept for the audit entry.
  def reject_forbidden_feature_changes
    guard = SuperAdmin::FeatureChangeGuard.new(action_name == 'create' ? Account.new : requested_resource)
    states = submitted_feature_states
    @feature_changes = guard.changes(states)
    message = guard.message(states)
    render_feature_rejection(message) if message
  end

  def render_feature_rejection(message)
    return render_card_error(message) if fine_tuning_only_request?

    flash.now[:alert] = message
    if action_name == 'create'
      render :new, locals: { page: Administrate::Page::Form.new(dashboard, new_resource) }, status: :unprocessable_content
    else
      render :edit, locals: { page: Administrate::Page::Form.new(dashboard, requested_resource) }, status: :unprocessable_content
    end
  end

  # { 'communication_threads' => { 'from' => false, 'to' => true } } for the owner-decision switches this request moves
  def owner_decision_changes
    @feature_changes.to_h.slice(*SuperAdmin::FineTuning::OWNER_DECISION_FLAGS).transform_values do |wanted|
      { 'from' => !wanted, 'to' => wanted }
    end
  end

  def record_owner_decision_audit(changes)
    record_super_admin_audit(OWNER_DECISION_AUDIT_ACTION, 'features' => changes)
  end

  # An account that cannot take the plan stays created; the operator is told and can apply it from the card.
  def apply_plan_to_new_account(account, modules)
    Accounts::ApplyPlan.new(account: account, modules: modules, actor: current_super_admin, request: request,
                            keep_existing_limits: true).call
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin] Plan apply on create failed for account #{account.id}: #{e.class.name}: #{e.message}")
    flash[:alert] = I18n.t('super_admin.accounts.flashes.plan_apply_failed')
  end

  # A new clinic speaks Russian until the operator picks another language (the column default is English)
  def new_resource(*)
    resource = super
    resource.locale = I18n.default_locale.to_s if action_name == 'new'
    resource
  end

  def start_trial_requested?
    ActiveModel::Type::Boolean.new.cast(params[:start_trial]) ? true : false
  end

  # The trial starts after the plan, so its snapshot holds the plan and the trial modules switch off when it ends.
  # An account that cannot take the trial stays created; the operator is told and can start it from the card.
  def start_trial_for_new_account(account)
    account.activate_trial!(Accounts::Plans.trial_days, keep_limits: true)
    SuperAdmin::AccountAudit.record(
      account: account, actor: current_super_admin, action: 'start_trial',
      changes: { 'trial_expires_at' => account.custom_attributes['trial_expires_at'] }, request: request
    )
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin] Trial on create failed for account #{account.id}: #{e.class.name}: #{e.message}")
    flash[:alert] = I18n.t('super_admin.accounts.flashes.trial_operation_failed')
  end

  # The notices of the account pages are worded for our own pages («Аккаунт создан»), not for the generic «Account»
  def translate_with_resource(key)
    I18n.t("super_admin.accounts.controller.#{key}", default: super)
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

  # The account page impersonates its first administrator; the user page names the member explicitly. A user who
  # is not a member of this account is never picked, so the grant stays scoped to one account membership.
  def impersonation_target_user
    return requested_resource.users.find_by(id: params[:user_id]) if params[:user_id].present?

    requested_resource.administrators.first || requested_resource.users.first
  end

  # Operator actions that change an account or reach into it leave an explicit entry in the audit log.
  def record_super_admin_audit(action, changes = {})
    SuperAdmin::AccountAudit.record(account: requested_resource, actor: current_super_admin, action: action, changes: changes, request: request)
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
