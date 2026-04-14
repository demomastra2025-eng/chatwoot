module SuperAdmin::NavigationHelper
  def settings_open?
    params[:controller].in? %w[super_admin/settings super_admin/app_configs]
  end

  def super_admin_resource_label(resource)
    resource_name = resource.respond_to?(:resource) ? resource.resource.to_s : resource.to_s

    return 'Workspace' if resource_name == 'accounts'

    model_name = resource_name.singularize.classify.safe_constantize&.model_name
    return model_name.human(count: 2) if model_name.present?

    resource_name.tr('/', ' ').tr('_', ' ').titleize
  end

  def settings_pages
    features = SuperAdmin::FeaturesHelper.available_features.select do |_feature, attrs|
      attrs['config_key'].present? && attrs['enabled']
    end

    # Add general at the beginning
    general_feature = [['general', { 'config_key' => 'general', 'name' => 'General' }]]

    general_feature + features.to_a
  end
end
