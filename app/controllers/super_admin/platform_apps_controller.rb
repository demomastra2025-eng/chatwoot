# The partner access of the super admin («Доступ по API для партнёров»): a key that lets the system of a partner create
# accounts and users through the Platform API. The token is shown in full ONCE, right after the access is created or the
# token is reissued; afterwards the pages show only its last 4 characters. Every change leaves an entry in the audit log.
class SuperAdmin::PlatformAppsController < SuperAdmin::ApplicationController
  # The key of the flash that carries the full token from the create / reissue request to the card
  ONE_TIME_TOKEN_KEY = :partner_token

  # The token and the counts of every row come with the list, not with a query per row
  def scoped_resource
    resource_class.includes(:access_token).with_counts
  end

  # Saves the partner, records the creation and shows the token (once) on its card
  def create
    super do |platform_app|
      record_audit(platform_app, 'create', 'name' => platform_app.name)
      flash[ONE_TIME_TOKEN_KEY] = platform_app.access_token&.token
    end
  end

  # Administrate's update does not yield, so the whole action is here: what changed goes to the audit log
  def update
    platform_app = requested_resource
    platform_app.assign_attributes(resource_params)
    changes = platform_app.changes.except('updated_at')

    if platform_app.save
      record_audit(platform_app, 'update', changes) if changes.any?
      redirect_to after_resource_updated_path(platform_app), notice: translate_with_resource('update.success')
    else
      render :edit, locals: { page: Administrate::Page::Form.new(dashboard, platform_app) }, status: :unprocessable_content
    end
  end

  def destroy
    platform_app = requested_resource
    snapshot = { 'name' => platform_app.name, 'accounts' => platform_app.accounts_count, 'users' => platform_app.users_count }
    if platform_app.destroy
      record_audit(platform_app, 'destroy', snapshot)
      flash[:notice] = translate_with_resource('destroy.success')
    else
      flash[:error] = platform_app.errors.full_messages.join(', ')
    end
    redirect_to action: :index
  end

  # A new token instead of the old one: the old one stops working at once. The new token is shown (once) on the card.
  def reissue_token
    platform_app = requested_resource
    token = platform_app.access_token || AccessToken.new(owner: platform_app)
    token.persisted? ? token.regenerate_token : token.save!
    record_audit(platform_app, 'reissue_token', 'token' => 'reissued')
    flash[ONE_TIME_TOKEN_KEY] = token.token
    redirect_to [namespace, platform_app], notice: I18n.t('super_admin.platform_apps.flashes.token_reissued')
  end

  private

  # The notices of these pages are worded for our own pages («Партнёрский доступ создан»), not for the generic «Platform app»
  def translate_with_resource(key)
    I18n.t("super_admin.platform_apps.controller.#{key}", default: super)
  end

  def record_audit(platform_app, action, changes)
    SuperAdmin::PlatformAudit.record(auditable: platform_app, action: action, actor: current_super_admin, changes: changes, request: request)
  end
end
