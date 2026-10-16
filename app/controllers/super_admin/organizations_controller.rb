# The organizations of the super admin: the paying parent of accounts. The pages are the Administrate ones restyled
# (index, new, edit) and the organization card (app/views/super_admin/organizations/show.html.erb). Every change leaves
# an entry in the audit log, and so do linking and unlinking an account (SuperAdmin::OrganizationLinks).
class SuperAdmin::OrganizationsController < SuperAdmin::ApplicationController
  # Saves the organization and records the creation
  def create
    super do |organization|
      record_audit(organization, 'create', created_changes(organization))
    end
  end

  # Administrate's update does not yield, so the whole action is here: what changed goes to the audit log
  def update
    organization = requested_resource
    organization.assign_attributes(resource_params)
    changes = organization.changes.except('updated_at')

    if organization.save
      record_audit(organization, 'update', changes) if changes.any?
      redirect_to after_resource_updated_path(organization), notice: translate_with_resource('update.success')
    else
      render :edit, locals: { page: Administrate::Page::Form.new(dashboard, organization) }, status: :unprocessable_content
    end
  end

  # An organization that still has accounts is not deleted: its accounts are unlinked first, one by one
  def destroy
    organization = requested_resource
    accounts = organization.accounts.count
    return redirect_to([namespace, organization], alert: flash_text('destroy_refused', count: accounts)) if accounts.positive?

    changes = created_changes(organization)
    organization.destroy!
    record_audit(organization, 'destroy', changes)
    redirect_to after_resource_destroyed_path(organization), notice: translate_with_resource('destroy.success')
  rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotDestroyed
    redirect_to [namespace, organization], alert: flash_text('destroy_refused', count: organization.accounts.count)
  end

  # Links an account that has no organization yet (an account of another organization is moved from its own page).
  # Whether the account is still free is decided under the lock of its row (SuperAdmin::OrganizationLinks), not by the
  # page: somebody may have linked it elsewhere since the select was drawn.
  def link_account
    account = Account.find_by(id: params[:account_id])
    return redirect_to_card(alert: flash_text('account_missing')) if account.nil?

    linked = organization_links.link(account: account, organization: requested_resource, expected_holder: nil).changed?
    redirect_to_card(notice: flash_text(linked ? 'account_linked' : 'account_already_linked', account: account.name))
  rescue SuperAdmin::OrganizationLinks::Refused => e
    redirect_to_card(alert: flash_text('account_taken', account: account.name, organization: e.holder.name))
  end

  # Unlinks an account of this organization; the account itself stays as it is. It is unlinked only if it is still
  # linked to THIS organization when its row is locked.
  def unlink_account
    account = Account.find_by(id: params[:account_id])
    return redirect_to_card(alert: flash_text('account_not_linked')) if account.nil?

    organization_links.unlink(account: account, expected_holder: requested_resource)
    redirect_to_card(notice: flash_text('account_unlinked', account: account.name))
  rescue SuperAdmin::OrganizationLinks::Refused
    redirect_to_card(alert: flash_text('account_not_linked'))
  end

  private

  # The list opens in the order of the names, A to Z; the header of a column changes it
  def order
    @order ||= SuperAdmin::OrganizationListOrder.new(
      params.fetch(resource_name, {}).fetch(:order, 'name'),
      params.fetch(resource_name, {}).fetch(:direction, 'asc')
    )
  end

  def organization_links
    SuperAdmin::OrganizationLinks.new(actor: current_super_admin, request: request)
  end

  def redirect_to_card(notice: nil, alert: nil)
    redirect_to [namespace, requested_resource], notice: notice, alert: alert
  end

  def flash_text(key, **)
    I18n.t("super_admin.organizations.flashes.#{key}", **)
  end

  # The notices of these pages are worded for our own pages («Организация создана»), not for the generic «Organization»
  def translate_with_resource(key)
    I18n.t("super_admin.organizations.controller.#{key}", default: super)
  end

  def record_audit(organization, action, changes)
    SuperAdmin::PlatformAudit.record(auditable: organization, action: action, actor: current_super_admin, changes: changes, request: request)
  end

  # The filled-in fields, the way the audit log keeps the fields of a created (or deleted) record
  def created_changes(organization)
    organization.attributes.except('id', 'created_at', 'updated_at', 'custom_attributes').compact
  end
end
