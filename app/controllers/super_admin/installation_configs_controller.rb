class SuperAdmin::InstallationConfigsController < SuperAdmin::ApplicationController
  # Configs that have a page of their own and must not be edited as raw text here: the platform switch of the channels
  # («Каналы») is a JSON map that the generic editor would let anyone break.
  RESERVED_CONFIG_NAMES = [Channels::PlatformVisibility::CONFIG_NAME].freeze

  rescue_from ActiveRecord::RecordNotUnique, :with => :invalid_action_perfomed
  before_action :reject_reserved_name

  # Overwrite any of the RESTful controller actions to implement custom behavior
  # For example, you may want to send an email after a foo is updated.
  #
  # def update
  #   super
  #   send_foo_updated_email(requested_resource)
  # end

  # Override this method to specify custom lookup behavior.
  # This will be used to set the resource for the `show`, `edit`, and `update`
  # actions.
  #
  # def find_resource(param)
  #   Foo.find_by!(slug: param)
  # end

  # The result of this lookup will be available as `requested_resource`

  # Override this if you have certain roles that require a subset
  # this will be used to set the records shown on the `index` action.
  #
  def scoped_resource
    resource_class.editable.where.not(name: RESERVED_CONFIG_NAMES)
  end

  # Override `resource_params` if you want to transform the submitted
  # data before it's persisted. For example, the following would turn all
  # empty values into nil values. It uses other APIs such as `resource_class`
  # and `dashboard`:
  #
  # def resource_params
  #   params.require(resource_class.model_name.param_key).
  #     permit(dashboard.permitted_attributes).
  #     transform_values { |value| value == "" ? nil : value }
  # end

  def resource_params
    params.require(:installation_config)
          .permit(:name, :value)
          .transform_values { |value| value == '' ? nil : value }.merge(locked: false)
  end

  # See https://administrate-prototype.herokuapp.com/customizing_controller_actions
  # for more information

  private

  # The list and the pages of a row never show a reserved config; this keeps a form from creating one or renaming another
  # row into one (a request without a name in it passes).
  def reject_reserved_name
    name = params.dig(:installation_config, :name)
    return unless name.is_a?(String) && RESERVED_CONFIG_NAMES.include?(name.strip.upcase)

    redirect_to super_admin_installation_configs_path, alert: I18n.t('super_admin.installation_configs.reserved', name: name.strip)
  end
end
