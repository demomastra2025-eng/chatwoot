require 'administrate/field/select'

# The role of a user (a plain user or a super admin). The form adds a confirmation input for the role of a super admin
# (the e-mail of the user typed in); SuperAdmin::UsersController reads it.
class UserTypeField < Administrate::Field::Select
end
