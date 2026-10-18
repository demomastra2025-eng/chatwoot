# The installation parameters as they are stored: a READ-ONLY list. Parameters are edited on the settings pages
# («Настройки»), where each field has its own check and every save is written to the audit log; this list only shows
# what is stored and links each parameter to the page that edits it. Secrets are never printed here (see
# SuperAdmin::InstallationConfigs), and there is no way to create, rename or change a parameter from this controller.
class SuperAdmin::InstallationConfigsController < SuperAdmin::ApplicationController
  # Configs that have a page of their own and are not listed: the platform switch of the channels («Каналы») is a JSON map
  RESERVED_CONFIG_NAMES = [Channels::PlatformVisibility::CONFIG_NAME].freeze

  # The parameters that the settings pages saved (the rows an operator has touched), without the reserved ones
  def scoped_resource
    resource_class.editable.where.not(name: RESERVED_CONFIG_NAMES)
  end
end
