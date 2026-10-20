# frozen_string_literal: true

# «Новый клиент»: one page that creates the account, its organization, its plan and its first administrator
# (SuperAdmin::ClientOnboarding), in place of the five pages it took before.
#
#   GET  /super_admin/clients/new   the form
#   POST /super_admin/clients       creates everything in one transaction, then shows «Готово» (the page itself, not a
#                                   redirect: a password the super admin set is shown ONCE, and nothing keeps it)
#
# A form with a problem is drawn again with everything that was typed and the problems under their fields (status 422).
#
# «Готово» is the response of the POST itself, so reloading it (F5, «Продолжить» of the browser) sends the form again. Every form
# carries a token of its own; the token of a form that created a client is kept in the session with the account, and the same form
# sent a second time gets «Клиент уже создан» with a link to the card, never a second account. A request without a token (a script)
# is created as it is.
class SuperAdmin::ClientsController < SuperAdmin::ApplicationController
  SUBMISSIONS_KEY = :client_submissions
  SUBMISSIONS_KEPT = 10
  TOKEN_FORMAT = /\A[0-9a-f]{32}\z/

  def new
    @form = SuperAdmin::ClientOnboarding::Form.blank
    @errors = {}
    @submission = SecureRandom.hex(16)
  end

  def create
    @form = SuperAdmin::ClientOnboarding::Form.from_params(params)
    @submission = submission_token
    # A password, typed or generated, is in this response and in the form that comes back after a mistake: never in a cache
    response.headers['Cache-Control'] = 'no-store'
    already = account_of_submission
    return render :already_created, locals: { account: already } if already

    onboarding = SuperAdmin::ClientOnboarding.new(@form, actor: current_super_admin, request: request).call
    return created(onboarding) if onboarding.success?

    @errors = onboarding.errors
    @conflict = onboarding.member.conflict
    render :new, status: :unprocessable_content
  end

  private

  def created(onboarding)
    remember_submission(onboarding.account)
    render :created, locals: { onboarding: onboarding }
  end

  # The token of the form in the request; a form of an old tab or a script has none (or a wrong one), and gets a new one
  def submission_token
    token = params[:submission]
    token.is_a?(String) && token.match?(TOKEN_FORMAT) ? token : SecureRandom.hex(16)
  end

  # The account this very form created before, nil when it created none (or the account is gone since)
  def account_of_submission
    id = submissions[@submission]
    Account.find_by(id: id) if id
  end

  # Only a form that came with its token is remembered: a request without one can never be sent "again"
  def remember_submission(account)
    return unless params[:submission] == @submission

    session[SUBMISSIONS_KEY] = submissions.merge(@submission => account.id).to_a.last(SUBMISSIONS_KEPT).to_h
  end

  def submissions
    kept = session[SUBMISSIONS_KEY]
    kept.is_a?(Hash) ? kept : {}
  end
end
