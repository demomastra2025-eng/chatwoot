require 'administrate/field/base'

# The value of an installation parameter on a list or a card. The stored value is dropped when the field is built and
# replaced by what a screen may show of it (SuperAdmin::InstallationConfigs.display), so no partial can print a secret.
class ConfigValueField < Administrate::Field::Base
  def initialize(attribute, _stored_value, page, options = {})
    super(attribute, SuperAdmin::InstallationConfigs.display(options[:resource]), page, options)
  end

  def to_s
    data.text.to_s
  end
end
