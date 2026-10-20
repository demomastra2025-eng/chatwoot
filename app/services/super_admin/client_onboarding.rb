# frozen_string_literal: true

# «Новый клиент»: the account, its organization, its plan and its first administrator, created by ONE action.
#
#   onboarding = SuperAdmin::ClientOnboarding.new(form, actor: current_super_admin, request: request).call
#   onboarding.success?    # false: nothing was written, `errors` says what to fix (field => text), the form is drawn again
#   onboarding.account     # the new account, with its organization, plan, trial and first administrator
#
# Everything is checked first (so the page shows every problem at once and keeps what was typed), then written inside one
# transaction: the account (Russian, with its time zone), the organization (a new one, or an existing one it is linked to),
# the plan (the base and the chosen modules: the limits come from it, nobody types them), the optional trial, and the
# administrator with his membership. If anything fails, nothing stays. The letter of the invitation is handed over after the
# commit. The entries of the audit log: the account (`create_client`), the plan and the trial (their own entries), the new
# organization, the link to it, the new user and the membership. A password is never written anywhere.
class SuperAdmin::ClientOnboarding
  NAME_LENGTH = 255
  AUDIT_ACTION = 'create_client'

  attr_reader :form, :errors, :account, :organization, :organization_created, :member, :trial_expires_at

  def initialize(form, actor:, request: nil)
    @form = form
    @actor = actor
    @request = request
    @errors = {}
    @member = SuperAdmin::AccountMember.new(form.admin, actor: actor, request: request)
  end

  def call
    validate
    return self if errors.any?

    Audited.audit_class.as_user(@actor) { create_everything }
    member.deliver_invitation if success?
    self
  end

  def success?
    errors.empty? && account.present?
  end

  # The modules in the form that the plans know (the form's own list, checked)
  def modules
    @modules ||= Accounts::Plans.normalize_modules(form.modules)
  end

  private

  def validate
    @errors = {}
    validate_account
    validate_organization
    validate_modules
    member.prepare.errors.each { |field, message| errors[:"admin_#{field}"] = message }
  end

  def validate_account
    name = form.account_name.to_s.squish
    errors[:account_name] = i18n('errors.account_name_blank') if name.blank?
    errors[:account_name] = i18n('errors.account_name_long', max: NAME_LENGTH) if name.length > NAME_LENGTH
    errors[:timezone] = i18n('errors.timezone_unknown') unless SuperAdmin::AccountTimezones.known?(form.timezone)
  end

  def validate_organization
    case form.organization_mode
    when 'none' then nil
    when 'existing' then validate_existing_organization
    when 'new' then validate_new_organization
    else errors[:organization_mode] = i18n('errors.organization_mode_unknown')
    end
  end

  def validate_existing_organization
    id = form.organization_id.to_s.strip
    @organization = Organization.find_by(id: id) if id.match?(/\A\d{1,18}\z/)
    errors[:organization_id] = i18n('errors.organization_missing') unless @organization
  end

  def validate_new_organization
    @organization = Organization.new(name: form.organization_name, bin: form.organization_bin)
    return if @organization.valid?

    @organization.errors.each do |error|
      errors[error.attribute == :bin ? :organization_bin : :organization_name] ||= organization_error_text(error)
    end
  end

  def organization_error_text(error)
    return i18n('errors.organization_name_blank') if error.attribute == :name && error.type == :blank
    return i18n('errors.organization_bin_taken') if error.attribute == :bin && error.type == :taken

    error.message
  end

  def validate_modules
    modules
  rescue ArgumentError
    errors[:modules] = I18n.t('super_admin.accounts.flashes.plan_unknown_module')
  end

  # One transaction: either everything below is saved or nothing is. A problem the checks could not foresee (an e-mail or a
  # БИН taken a moment ago by somebody else, a failure of the database) is shown as an error on the page and logged.
  def create_everything
    ApplicationRecord.transaction do
      create_organization
      @account = create_account
      link_organization
      apply_plan
      start_trial
      member.add_to(account)
      record_audit
    end
  rescue StandardError => e
    rolled_back(e)
  end

  def create_organization
    return unless form.organization_mode == 'new'

    organization.save!
    @organization_created = true
    SuperAdmin::PlatformAudit.record(
      auditable: organization, action: 'create', actor: @actor, request: @request,
      changes: organization.attributes.except('id', 'created_at', 'updated_at', 'custom_attributes').compact
    )
  end

  # Russian and with its time zone: the zone is the one the report days and the working hours of the account follow
  def create_account
    Account.create!(name: form.account_name.to_s.squish, locale: I18n.default_locale.to_s,
                    reporting_timezone: form.timezone, workspace_timezone: form.timezone)
  end

  def link_organization
    return unless organization

    SuperAdmin::OrganizationLinks.new(actor: @actor, request: @request).link(account: account, organization: organization, expected_holder: nil)
  end

  # The limits of the plan fill the blanks of the new account (nothing is asked for them here)
  def apply_plan
    Accounts::ApplyPlan.new(account: account, modules: modules, actor: @actor, request: @request, keep_existing_limits: true).call
  end

  def start_trial
    return unless form.start_trial

    account.activate_trial!(Accounts::Plans.trial_days, keep_limits: true)
    @trial_expires_at = account.custom_attributes['trial_expires_at']
    SuperAdmin::AccountAudit.record(account: account, actor: @actor, action: 'start_trial',
                                    changes: { 'trial_expires_at' => trial_expires_at }, request: @request)
  end

  def record_audit
    SuperAdmin::AccountAudit.record(account: account, actor: @actor, action: AUDIT_ACTION, request: @request, changes: audit_changes)
  end

  def audit_changes
    {
      'name' => account.name, 'timezone' => form.timezone, 'organization_id' => organization&.id,
      'organization_name' => organization&.name, 'organization_created' => organization_created ? true : false,
      'modules' => modules, 'trial' => form.start_trial ? true : false,
      'administrator' => { 'email' => member.user.email, 'access' => member.access.to_s }
    }
  end

  # Nothing was saved: forget the half-built objects and say what went wrong, on the field when it is one
  def rolled_back(error)
    Rails.logger.warn("[SuperAdmin] New client was not created: #{error.class.name}: #{error.message}")
    @account = nil
    @organization_created = nil
    @trial_expires_at = nil
    @errors = rolled_back_errors(error)
  end

  def rolled_back_errors(error)
    record = error.respond_to?(:record) ? error.record : nil
    return { admin_email: member_taken_text } if record.is_a?(User) || user_email_race?(error)
    return { organization_bin: record.errors[:bin].first || i18n('errors.failed') } if record.is_a?(Organization) && record.errors[:bin].any?

    { base: i18n('errors.failed') }
  end

  def user_email_race?(error)
    error.is_a?(ActiveRecord::RecordNotUnique) && error.message.include?('users')
  end

  def member_taken_text
    I18n.t('super_admin.onboarding.member.errors.email_taken', name: User.from_email(form.admin.email)&.name.to_s)
  end

  def i18n(key, **)
    I18n.t("super_admin.onboarding.#{key}", **)
  end
end
