# frozen_string_literal: true

# The problems of a form drawn by hand (not by Administrate), shown where a person looks for them: under the field, in red,
# with the control turned red too. `errors` is a map of field => text (SuperAdmin::ClientOnboarding#errors).
#
#   <%= super_admin_with_error(errors, :email) do %> <input ...> <% end %>
#   <%= super_admin_field_error(errors, :email) %>
module SuperAdmin::FormErrorsHelper
  # The text of the problem under the field; nothing for a field without one
  def super_admin_field_error(errors, key)
    return if errors[key].blank?

    tag.p(errors[key], class: 'm-0 text-xs text-n-ruby-11', role: 'alert', data: { error_for: key })
  end

  # Rails' own wrapper of an invalid field: the shell styles it (the control and its label turn red)
  def super_admin_with_error(errors, key, &)
    tag.div(class: ('field_with_errors' if errors[key].present?), &)
  end
end
