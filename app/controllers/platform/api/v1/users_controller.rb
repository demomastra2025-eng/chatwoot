# Users of the partner. A partner creates users and works only with the users IT created: a user that exists already
# (an operator of another customer, a super admin) is never attached to the partner, whatever e-mail is sent, and a
# super admin is never reachable through the Platform API at all.
class Platform::Api::V1::UsersController < PlatformController
  # The fields of a user whose change is written to the audit log (never a password, a token or a key)
  AUDITED_USER_FIELDS = %w[name display_name email].freeze

  # ref: https://stackoverflow.com/a/45190318/939299
  # set resource is called for other actions already in platform controller
  # we want to add login and token to that chain as well
  before_action(only: [:login, :token]) { set_resource }
  before_action(only: [:login, :token]) { validate_platform_app_permissible }
  before_action :reject_super_admin, only: [:show, :update, :destroy, :login, :token]

  def show; end

  # An e-mail that is taken answers 409. The partner's own user with that e-mail is returned as it is (creating it
  # again changes nothing), so a call that was repeated is harmless.
  def create
    existing = User.from_email(user_params[:email])
    return render_email_taken if existing && !returnable_own_user?(existing)

    @resource = existing || create_user
    audit_record(@resource, 'partner_create_user', user_snapshot(@resource)) unless existing
  end

  def login
    audit_record(@resource, 'partner_login_link', 'email' => @resource.email)
    render json: { url: @resource.generate_sso_link }
  end

  def token
    audit_record(@resource, 'partner_user_token', 'email' => @resource.email)
  end

  def update
    @resource.assign_attributes(user_update_params)

    # We are using devise's reconfirmable flow for changing emails
    # But in case of platform APIs we don't want user to go through this extra step
    @resource.skip_reconfirmation! if user_update_params[:email].present?
    changes = audited_changes(@resource)
    @resource.save!
    audit_record(@resource, 'partner_update_user', changes) if changes.any?
  end

  def destroy
    snapshot = user_snapshot(@resource)
    DeleteObjectJob.perform_later(@resource)
    audit_record(@resource, 'partner_destroy_user', snapshot)
    head :ok
  end

  private

  def create_user
    user = User.new(user_params)
    user.skip_confirmation!
    ActiveRecord::Base.transaction do
      user.save!
      @platform_app.platform_app_permissibles.find_or_create_by!(permissible: user)
    end
    user
  end

  def returnable_own_user?(user)
    @platform_app.owns?(user) && !user.is_a?(SuperAdmin)
  end

  # The same answer for every existing user, so it does not tell a partner what kind of user owns the e-mail
  def render_email_taken
    render json: { error: 'A user with this email already exists', code: 'email_taken' }, status: :conflict
  end

  # A super admin is not a customer's user: it looks like any resource the partner has no access to
  def reject_super_admin
    render_non_permissible if @resource.is_a?(SuperAdmin)
  end

  def user_custom_attributes
    return @resource.custom_attributes.merge(user_params[:custom_attributes]) if user_params[:custom_attributes]

    @resource.custom_attributes
  end

  def user_update_params
    # we want the merged custom attributes not the original one
    user_params.except(:custom_attributes).merge({ custom_attributes: user_custom_attributes })
  end

  # What a change of the user shows in the audit log: the changed fields with the old and the new value, and only the
  # NAME of what is secret ('password') or long ('custom_attributes')
  def audited_changes(user)
    changes = user.changes.slice(*AUDITED_USER_FIELDS)
    changes['password'] = 'changed' if user.encrypted_password_changed?
    changes['custom_attributes'] = 'changed' if user.custom_attributes_changed?
    changes
  end

  def user_snapshot(user)
    user.attributes.slice(*AUDITED_USER_FIELDS).compact
  end

  def set_resource
    @resource = User.find(params[:id])
  end

  def user_params
    params.permit(:name, :display_name, :email, :password, custom_attributes: {})
  end
end
