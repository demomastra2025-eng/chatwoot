# frozen_string_literal: true

# The sign-in of the super admin: e-mail and password, and a second step (a code from the authenticator app, or a backup
# code) when the super admin has two-factor authentication on for his user (the same MFA the operator app uses, see
# Mfa::ManagementService). Nobody is forced to turn it on: a super admin without it signs in with the password alone, and
# «Сводка» tells him where to enable it. Every sign-in, failed attempt, wrong code and sign-out is written to the audit log.
#
# Between the two steps the password is already checked but the person is NOT signed in: only his id, the time and the
# number of wrong codes are kept in the session, for a few minutes.
class SuperAdmin::Devise::SessionsController < Devise::SessionsController
  TWO_FACTOR_SESSION_KEY = 'super_admin_two_factor'
  # How long the second step stays open after the password, and how many wrong codes it takes
  TWO_FACTOR_WINDOW = 5.minutes
  TWO_FACTOR_ATTEMPTS = 5

  prepend_before_action :require_no_authentication, only: [:two_factor, :verify_two_factor]

  def new
    self.resource = resource_class.new(sign_in_params)
  end

  def create
    super_admin = SuperAdmin.find_by(email: submitted_email)
    unless super_admin&.valid_password?(submitted_password)
      audit_failed_sign_in(super_admin)
      return redirect_to(super_admin_session_path, flash: { error: I18n.t('devise.failure.invalid', authentication_keys: 'email') })
    end
    return start_two_factor(super_admin) if super_admin.mfa_enabled?

    finish_sign_in(super_admin)
  end

  # The page of the second step
  def two_factor
    @super_admin = pending_super_admin
    return redirect_to(super_admin_session_path, flash: { error: I18n.t('super_admin.two_factor.expired') }) unless @super_admin
  end

  def verify_two_factor
    super_admin = pending_super_admin
    return redirect_to(super_admin_session_path, flash: { error: I18n.t('super_admin.two_factor.expired') }) unless super_admin

    method = second_factor_method(super_admin)
    return finish_sign_in(super_admin, second_factor: method) if method

    reject_second_factor(super_admin)
  end

  def destroy
    audit_sign_out(warden.user(:super_admin))
    sign_out
    flash.discard
    redirect_to '/'
  end

  private

  # The audit log asks the controller who is signed in as a user of the operator app (Audited::Sweeper). The helper that
  # DeviseTokenAuth puts on this controller fails inside a Devise controller, and nobody is signed in as a user here, so
  # the answer is «nobody»; the super admin is passed to the audit explicitly.
  def current_user = nil

  def submitted_email
    params.dig(:super_admin, :email).to_s.strip.downcase
  end

  def submitted_password
    params.dig(:super_admin, :password).to_s
  end

  def finish_sign_in(super_admin, second_factor: nil)
    session.delete(TWO_FACTOR_SESSION_KEY)
    sign_in(:super_admin, super_admin)
    flash.discard
    audit('super_admin_login', super_admin, actor: super_admin, changes: second_factor ? { 'second_factor' => second_factor } : {})
    redirect_to super_admin_root_path
  end

  def start_two_factor(super_admin)
    session[TWO_FACTOR_SESSION_KEY] = { 'id' => super_admin.id, 'at' => Time.current.to_i, 'wrong_codes' => 0 }
    redirect_to super_admin_two_factor_path
  end

  # The super admin whose password was checked a moment ago; nil when there is none or the time is over
  def pending_super_admin
    pending = session[TWO_FACTOR_SESSION_KEY]
    return unless pending.is_a?(Hash)

    if Time.zone.at(pending['at'].to_i) < TWO_FACTOR_WINDOW.ago
      session.delete(TWO_FACTOR_SESSION_KEY)
      return
    end
    SuperAdmin.find_by(id: pending['id'])
  end

  # 'authenticator' or 'backup_code' when the code is right, nil when it is not
  def second_factor_method(super_admin)
    otp_code = params[:otp_code].to_s.gsub(/\s+/, '')
    backup_code = params[:backup_code].to_s.gsub(/\s+/, '').upcase
    return if otp_code.blank? && backup_code.blank?

    accepted = Mfa::AuthenticationService.new(user: super_admin, otp_code: otp_code.presence, backup_code: otp_code.present? ? nil : backup_code).authenticate
    return unless accepted

    otp_code.present? ? 'authenticator' : 'backup_code'
  rescue StandardError => e
    # e.g. the encryption keys are missing: the code cannot be checked, so it is not accepted
    Rails.logger.error("[SuperAdmin] Second factor check failed: #{e.class.name}: #{e.message}")
    nil
  end

  def reject_second_factor(super_admin)
    pending = session[TWO_FACTOR_SESSION_KEY]
    wrong_codes = pending['wrong_codes'].to_i + 1
    session[TWO_FACTOR_SESSION_KEY] = pending.merge('wrong_codes' => wrong_codes)
    audit('super_admin_two_factor_failed', super_admin, changes: { 'wrong_codes' => wrong_codes })
    if wrong_codes >= TWO_FACTOR_ATTEMPTS
      session.delete(TWO_FACTOR_SESSION_KEY)
      return redirect_to(super_admin_session_path, flash: { error: I18n.t('super_admin.two_factor.too_many') })
    end

    redirect_to super_admin_two_factor_path, flash: { error: I18n.t('super_admin.two_factor.wrong_code') }
  end

  def audit_failed_sign_in(super_admin)
    if super_admin
      audit('super_admin_login_failed', super_admin, changes: { 'reason' => 'wrong_password' })
    else
      SuperAdmin::PlatformAudit.record(auditable: nil, action: 'super_admin_login_failed', changes: { 'reason' => 'unknown_email' },
                                       request: request, username: submitted_email)
    end
  end

  def audit_sign_out(super_admin)
    audit('super_admin_logout', super_admin, actor: super_admin) if super_admin
  end

  # An entry about a super admin; actor is him when he did it himself (signed in or out), nobody for an attempt that failed
  def audit(action, super_admin, actor: nil, changes: {})
    SuperAdmin::PlatformAudit.record(auditable: super_admin, action: action, actor: actor, changes: changes, request: request)
  end
end
