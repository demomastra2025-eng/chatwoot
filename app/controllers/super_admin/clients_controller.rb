# frozen_string_literal: true

# «Новый клиент»: one page that creates the account, its organization, its plan and its first administrator
# (SuperAdmin::ClientOnboarding), in place of the five pages it took before.
#
#   GET  /super_admin/clients/new   the form
#   POST /super_admin/clients       creates everything in one transaction, then shows «Готово» (the page itself, not a
#                                   redirect: a password the super admin set is shown ONCE, and nothing keeps it)
#
# A form with a problem is drawn again with everything that was typed and the problems under their fields (status 422).
class SuperAdmin::ClientsController < SuperAdmin::ApplicationController
  def new
    @form = SuperAdmin::ClientOnboarding::Form.blank
    @errors = {}
  end

  def create
    @form = SuperAdmin::ClientOnboarding::Form.from_params(params)
    onboarding = SuperAdmin::ClientOnboarding.new(@form, actor: current_super_admin, request: request).call
    # A password, typed or generated, is in this response and in the form that comes back after a mistake: never in a cache
    response.headers['Cache-Control'] = 'no-store'
    return render :created, locals: { onboarding: onboarding } if onboarding.success?

    @errors = onboarding.errors
    @conflict = onboarding.member.conflict
    render :new, status: :unprocessable_content
  end
end
