class SuperAdmin::UsersController < SuperAdmin::ApplicationController
  # The roles the form offers: a plain user ('') or a super admin. Nothing else is a role.
  ROLES = ['', 'SuperAdmin'].freeze

  # What a super admin does to users is audited: the changes of the name, e-mail and role are written by the model (see
  # Enterprise::Audit::User) as made by THIS super admin; a new password is written below as «changed», never as a value.
  # (`destroy` is Administrate's own action, so the filters name an action this class does not define itself)
  around_action :audit_as_current_super_admin, only: %i[create update destroy] # rubocop:disable Rails/LexicallyScopedActionFilter
  before_action :guard_role, only: %i[create update]
  before_action :guard_removal, only: :destroy # rubocop:disable Rails/LexicallyScopedActionFilter

  # Overwrite any of the RESTful controller actions to implement custom behavior
  # For example, you may want to send an email after a foo is updated.

  def create
    resource = resource_class.new(resource_params)
    authorize_resource(resource)

    if resource.save
      redirect_to super_admin_user_path(resource), notice: translate_with_resource('create.success')
    else
      notice = resource.errors.full_messages.first
      redirect_to new_super_admin_user_path, notice: notice
    end
  end

  def update
    password_changed = resource_params[:password].present?
    requested_resource.skip_reconfirmation! if resource_params[:confirmed_at].present?
    super
    record_password_change if password_changed && response.redirect?
  end

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

  def destroy_avatar
    avatar = requested_resource.avatar
    avatar.purge
    redirect_back(fallback_location: super_admin_users_path)
  end

  def scoped_resource
    resource_class.with_attached_avatar
  end

  def resource_params
    permitted_params = super
    permitted_params.delete(:password) if permitted_params[:password].blank?
    fill_blank_name(permitted_params)
    permitted_params
  end

  # See https://administrate-prototype.herokuapp.com/customizing_controller_actions
  # for more information
  def find_resource(param)
    super.becomes(User)
  end

  private

  def audit_as_current_super_admin(&)
    Audited.audit_class.as_user(current_super_admin, &)
  end

  def record_password_change
    SuperAdmin::PlatformAudit.record(
      auditable: requested_resource, action: 'change_password', actor: current_super_admin,
      changes: { 'password' => 'changed' }, request: request
    )
  end

  # Runs before create and update. A role is changed only to a known one; making someone a super admin needs their e-mail
  # typed into the confirmation field; a super admin cannot take the role away from himself or from the last super admin.
  def guard_role
    submitted = params[:user]
    return unless submitted.respond_to?(:key?) && submitted.key?(:type)

    reason = role_refusal(submitted[:type].to_s, submitted)
    refuse_role(reason) if reason
  end

  # Why the role in the request is refused (a key of super_admin.users.refused), nil when it may be set
  def role_refusal(wanted, submitted)
    return :unknown_role unless ROLES.include?(wanted)

    current = action_name == 'create' ? '' : requested_resource.type.to_s
    return if wanted == current
    return :confirmation_missing if wanted == 'SuperAdmin' && !super_admin_confirmed?(submitted)

    demotion_refusal if wanted != 'SuperAdmin'
  end

  # The e-mail the new super admin will have, typed into the confirmation field
  def super_admin_confirmed?(submitted)
    email = submitted[:email].presence || (requested_resource.email unless action_name == 'create')
    typed = submitted[:super_admin_confirmation].to_s.strip.downcase
    typed.present? && typed == email.to_s.strip.downcase
  end

  # nil when the role of the user in the request may be taken away
  def demotion_refusal
    return :demote_self if requested_resource.id == current_super_admin.id

    :demote_last if SuperAdmin.count <= 1
  end

  def guard_removal
    user = requested_resource
    return refuse_removal(:delete_self) if user.id == current_super_admin.id

    refuse_removal(:delete_last) if user.type == 'SuperAdmin' && SuperAdmin.count <= 1
  end

  def refuse_role(reason)
    flash[:alert] = I18n.t("super_admin.users.refused.#{reason}")
    redirect_to action_name == 'create' ? new_super_admin_user_path : edit_super_admin_user_path(requested_resource)
  end

  def refuse_removal(reason)
    redirect_to super_admin_user_path(requested_resource), alert: I18n.t("super_admin.users.refused.#{reason}")
  end

  # users.name is required, but the admin form lets the operator fill only the display name.
  # Administrate turns blank strings into nil, so fall back to the display name and then to
  # the part of the email before "@" instead of failing with a database error.
  def fill_blank_name(permitted_params)
    return unless action_name == 'create' || permitted_params.key?(:name)
    return if permitted_params[:name].present?

    permitted_params[:name] = permitted_params[:display_name].presence || email_local_part(permitted_params)
  end

  def email_local_part(permitted_params)
    email = permitted_params[:email].presence || (requested_resource.email if action_name != 'create')
    email.to_s.split('@').first.to_s
  end
end
