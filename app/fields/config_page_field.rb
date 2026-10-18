require 'administrate/field/base'

# The settings page that edits an installation parameter (the key of the page, nil for a parameter no page edits)
class ConfigPageField < Administrate::Field::Base
  def title
    SuperAdmin::AppConfigLabels.page_title(data) if data.present?
  end
end
