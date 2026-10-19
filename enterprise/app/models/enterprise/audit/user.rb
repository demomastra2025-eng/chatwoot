module Enterprise::Audit::User
  extend ActiveSupport::Concern

  included do
    # What changes about a person: the name, the e-mail and the role (a plain user or a super admin). Passwords, tokens
    # and the second-factor secrets are not in the list, so they never reach the audit log. The availability (online,
    # busy) changes all day and is left out. A new user is not written here (signing up and inviting create users all day):
    # the super admin writes the creation of a user itself, and the sign-in and sign-out entries are written by hand (the
    # sessions controller), through the `audits` association this call adds.
    audited only: [
      :display_name,
      :email,
      :name,
      :type
    ], on: [:update, :destroy]
  end
end
