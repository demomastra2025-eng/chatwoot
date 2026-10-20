# frozen_string_literal: true

# A person a super admin brings into an account, in one of two ways:
#
# * `pick`   - somebody who is on the platform already, chosen from the list (nothing about them changes);
# * `create` - a person typed by e-mail and name, who gets access one of two ways the super admin chooses:
#     - `invitation`: a letter with a link where they set their own password (the letter every invited operator gets);
#     - `password`: a password the super admin sets and hands over; the person is confirmed at once and can sign in.
#   An e-mail that belongs to a user already is never created again, and that user's password and data never change: the
#   super admin has to say «add this user» (`adopt`) first, and then they join as they are.
#
# Used by the page «Новый клиент» (the first administrator) and the «Пользователи» block of the account card. It works in
# two steps so the page can show every problem at once and keep what was typed:
#
#   member = SuperAdmin::AccountMember.new(input, actor: current_super_admin, request: request).prepare(account: account)
#   member.errors                      # { email: '...', password: '...' }; nothing is written by `prepare`
#   member.add_to(account)             # inside the caller's transaction: the user and the membership
#   member.deliver_invitation          # AFTER the transaction is committed: the letter
#
# A secret is never written to the audit log: only the name of the way the person got access.
class SuperAdmin::AccountMember
  ACCESS = %w[invitation password].freeze
  ROLES = %w[agent administrator].freeze
  # Like the temporary password of an invited operator (AgentBuilder): it satisfies the password rules and nobody knows it
  TEMPORARY_PASSWORD_PREFIX = '1!aA'
  NAME_LENGTH = 255

  Input = Struct.new(:mode, :user_id, :email, :name, :role, :access, :password, :adopt, keyword_init: true) do
    # The input of a request: only text counts (an array or a map where a string is expected is an empty value)
    def self.from_params(raw, **defaults)
      values = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
      text = ->(key) { values[key.to_s].is_a?(String) ? values[key.to_s] : nil }
      new(
        mode: text.call(:mode) || defaults[:mode], user_id: text.call(:user_id), email: text.call(:email), name: text.call(:name),
        role: text.call(:role) || defaults[:role], access: text.call(:access) || defaults[:access], password: text.call(:password),
        adopt: ActiveModel::Type::Boolean.new.cast(text.call(:adopt)) || false
      )
    end
  end

  # The person was not found or is already in the account, or the input is not what it should be: `errors` says what
  attr_reader :input, :errors, :user, :membership, :conflict, :delivery

  def initialize(input, actor:, request: nil)
    @input = input
    @actor = actor
    @request = request
    @errors = {}
    @created = false
  end

  # Checks everything that can be checked without writing; the problems are in `errors` (field => text). With the account
  # (a person who is added to an existing one) it also checks that they are not in it yet.
  def prepare(account: nil)
    @errors = {}
    @conflict = nil
    @user = nil
    error(:role, :role_unknown) unless ROLES.include?(input.role)
    input.mode == 'pick' ? prepare_picked(account) : prepare_new(account)
    self
  end

  def valid?
    errors.empty?
  end

  # Writes the user (when they are new) and the membership. Call it inside a transaction: nothing else here opens one.
  def add_to(account)
    @account = account
    @user ||= create_user!
    @membership = AccountUser.create!(membership_attributes(account))
    self
  end

  # The letter of the invitation: after the commit, so the job never runs before the user exists. A new user with an
  # invitation only. A failure to hand the letter over does not undo the creation: `delivery` says `failed` and the page tells
  # the super admin to set a password instead.
  def deliver_invitation
    return unless invitation?

    send_invitation
  end

  def created?
    @created
  end

  def invitation?
    created? && input.access == 'invitation'
  end

  # :invitation, :password or :existing (somebody who was on the platform already)
  def access
    created? ? input.access.to_sym : :existing
  end

  # The password the super admin set, for the page that shows it once; nil for any other way
  def one_time_password
    input.password if created? && input.access == 'password'
  end

  # What the audit log of the account keeps about the person (never a password)
  def audit_changes
    { 'user_id' => user.id, 'email' => user.email, 'role' => membership.role, 'new_user' => created?, 'access' => access.to_s }
  end

  private

  # The letter that tells the person to set a password goes out with the account in view of the mailer (its language and name)
  def send_invitation
    previous = Current.account
    Current.account = @account
    user.send_confirmation_instructions
    @delivery = :queued
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin] Invitation to user #{user&.id} was not queued: #{e.class.name}: #{e.message}")
    @delivery = :failed
  ensure
    Current.account = previous
  end

  def prepare_picked(account)
    id = input.user_id.to_s.strip
    @user = User.find_by(id: id) if id.match?(/\A\d{1,18}\z/)
    return error(:user, :pick_missing) unless @user

    refuse_member(account)
  end

  def prepare_new(account)
    email = input.email.to_s.strip.downcase
    return error(:email, :email_blank) if email.blank?
    return error(:email, :email_invalid) unless email.match?(Devise.email_regexp)

    existing = User.from_email(email)
    return prepare_existing(existing, account) if existing

    prepare_name
    prepare_access
  end

  # The e-mail is somebody's already. They are added only when the super admin said so; nothing about them changes.
  def prepare_existing(existing, account)
    @conflict = existing
    return error(:email, :email_taken, name: existing.name) unless input.adopt

    @user = existing
    refuse_member(account)
  end

  def prepare_name
    name = input.name.to_s.squish
    return error(:name, :name_blank) if name.blank?

    error(:name, :name_long, max: NAME_LENGTH) if name.length > NAME_LENGTH
  end

  def prepare_access
    case input.access
    when 'invitation'
      error(:access, :mail_off) unless SuperAdmin::MailState.configured?
    when 'password'
      prepare_password
    else
      error(:access, :access_missing)
    end
  end

  def prepare_password
    return error(:password, :password_blank) if input.password.to_s.empty?

    message = SuperAdmin::PasswordRules.message(input.password)
    errors[:password] = message if message
  end

  def refuse_member(account)
    membership = account&.account_users&.find_by(user_id: user.id)
    return unless membership

    error(:user, :already_member, name: user.name, role: I18n.t("super_admin.account_users.roles.#{membership.role}").downcase)
  end

  def error(field, key, **values)
    errors[field] = I18n.t("super_admin.onboarding.member.errors.#{key}", **values)
  end

  def create_user!
    password = input.access == 'password' ? input.password : temporary_password
    new_user = User.new(email: input.email.to_s.strip.downcase, name: input.name.to_s.squish, password: password, password_confirmation: password)
    # A password the super admin set is final: the person signs in with it. An invitation is confirmed when the person sets
    # their own password from the letter, and the letter is sent by `deliver_invitation`, not by the creation.
    input.access == 'password' ? new_user.skip_confirmation! : new_user.skip_confirmation_notification!
    new_user.save!
    @created = true
    record_creation(new_user)
    new_user
  end

  def temporary_password
    "#{TEMPORARY_PASSWORD_PREFIX}#{SecureRandom.alphanumeric(12)}"
  end

  def membership_attributes(account)
    attributes = { account: account, user: @user, role: input.role, inviter: @actor }
    # Somebody who has never signed in is not online (and not offered conversations) until they are
    attributes[:availability] = :offline if created?
    attributes
  end

  def record_creation(new_user)
    SuperAdmin::PlatformAudit.record(
      auditable: new_user, action: 'create', actor: @actor, request: @request,
      changes: new_user.attributes.slice('name', 'display_name', 'email', 'type').compact.merge('access' => input.access)
    )
  end
end
