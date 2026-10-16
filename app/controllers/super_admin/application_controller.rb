# All Administrate controllers inherit from this
# `Administrate::ApplicationController`, making it the ideal place to put
# authentication logic or other before_actions.
#
# If you want to add pagination or other controller-level concerns,
# you're free to overwrite the RESTful controller actions.
class SuperAdmin::ApplicationController < Administrate::ApplicationController
  include ActionView::Helpers::TagHelper
  include ActionView::Context
  include SuperAdmin::NavigationHelper
  include SwitchLocale

  helper SuperAdmin::NavigationHelper
  helper SuperAdmin::DisplayHelper
  helper_method :render_vue_component, :settings_open?, :settings_pages, :super_admin_resource_label
  # authenticiation done via devise : SuperAdmin Model
  before_action :authenticate_super_admin!
  around_action :switch_locale

  # Override this value to specify the number of elements to display at a time
  # on index pages. Defaults to 20.
  # def records_per_page
  #   params[:per_page] || 20
  # end

  def order
    @order ||= Administrate::Order.new(
      params.fetch(resource_name, {}).fetch(:order, 'id'),
      params.fetch(resource_name, {}).fetch(:direction, 'desc')
    )
  end

  # Every date and time input of a form holds Astana wall-clock time (app/views/fields/date_time/_form.html.erb), so it
  # is turned back into a moment here, for the attributes of ANY dashboard that are edited as a date and time. A
  # controller that overrides this method calls `super`.
  def resource_params
    permitted = super
    astana_input_attributes.each do |name|
      permitted[name] = SuperAdmin::DisplayHelper.parse_input(permitted[name]) if permitted.key?(name)
    end
    permitted
  end

  private

  # The attributes of the dashboard that are edited with the datetime input (Field::DateTime and its subclasses)
  def astana_input_attributes
    dashboard.attribute_types.filter_map do |name, type|
      field_class = type.respond_to?(:deferred_class) ? type.deferred_class : type
      name if field_class.is_a?(Class) && field_class <= Administrate::Field::DateTime
    end
  end

  def render_vue_component(component_name, props = {})
    html_options = {
      id: 'app',
      data: {
        component_name: component_name,
        props: props.to_json
      }
    }
    content_tag(:div, '', html_options)
  end

  def invalid_action_perfomed
    flash[:error] = I18n.t('super_admin.flashes.invalid_action')
    redirect_back(fallback_location: root_path)
  end
end
