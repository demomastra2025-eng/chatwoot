# The notices the platform shows on top of every operator screen. They work on any installation: a clinic platform on its
# own server uses them for the announcements of technical works.
#
# A banner reaches the operators of every account, so it is never shown by accident: a new banner is a DRAFT (the form has no
# switch «показывать»), and it is shown only by «Показать всем операторам», which asks first and says how many accounts will
# see it (SuperAdmin::PlatformBannersController#publish). Everything that is done to a banner leaves an entry of the audit log.
class SuperAdmin::PlatformBannersController < SuperAdmin::ApplicationController
  # A new banner is saved as a draft. (The column is `true` by default for the banners made by scripts; the form never sends it.)
  def create
    super do |banner|
      record_audit(banner, 'create', created_changes(banner))
    end
  end

  # Administrate's update does not yield, so the whole action is here: what changed goes to the audit log
  def update
    banner = requested_resource
    banner.assign_attributes(resource_params)
    changes = banner.changes.except('updated_at')

    if banner.save
      record_audit(banner, 'update', changes.merge('active' => banner.active)) if changes.any?
      redirect_to after_resource_updated_path(banner), notice: translate_with_resource('update.success')
    else
      render :edit, locals: { page: Administrate::Page::Form.new(dashboard, banner) }, status: :unprocessable_content
    end
  end

  def destroy
    banner = requested_resource
    snapshot = created_changes(banner)
    if banner.destroy
      record_audit(banner, 'destroy', snapshot)
      flash[:notice] = translate_with_resource('destroy.success')
    else
      flash[:error] = banner.errors.full_messages.join(', ')
    end
    redirect_to action: :index
  end

  # «Показать всем операторам»: the banner is shown on top of the screens of every active account from now on
  def publish
    banner = requested_resource
    return redirect_to([namespace, banner], alert: flash_text(:already_shown)) if banner.active?

    accounts = PlatformBanner.reach
    banner.update!(active: true)
    record_audit(banner, 'publish_banner', created_changes(banner).merge('accounts' => accounts))
    redirect_to [namespace, banner], notice: flash_text(:published, count: accounts)
  end

  # «Скрыть у всех»: the banner stays (as a draft), nobody sees it
  def hide
    banner = requested_resource
    return redirect_to([namespace, banner], alert: flash_text(:already_hidden)) unless banner.active?

    banner.update!(active: false)
    record_audit(banner, 'hide_banner', created_changes(banner))
    redirect_to [namespace, banner], notice: flash_text(:hidden)
  end

  private

  # A banner made on the form starts hidden
  def new_resource(*args)
    resource = super
    resource.active = false if %w[new create].include?(action_name)
    resource
  end

  # The notices of these pages are worded for our own pages («Баннер создан»), not for the generic «Platform banner»
  def translate_with_resource(key)
    I18n.t("super_admin.platform_banners.controller.#{key}", default: super)
  end

  def flash_text(key, **)
    I18n.t("super_admin.platform_banners.flashes.#{key}", **)
  end

  def record_audit(banner, action, changes)
    SuperAdmin::PlatformAudit.record(auditable: banner, action: action, actor: current_super_admin, changes: changes, request: request)
  end

  def created_changes(banner)
    banner.attributes.slice('banner_message', 'banner_type', 'active')
  end
end
