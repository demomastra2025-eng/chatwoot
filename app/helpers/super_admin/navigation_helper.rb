module SuperAdmin::NavigationHelper
  def settings_open?
    params[:controller].in? %w[super_admin/settings super_admin/app_configs]
  end

  def super_admin_resource_label(resource)
    resource_name = if resource.respond_to?(:resource)
                      resource.resource.to_s
                    else
                      resource.to_s
                    end

    return 'Workspace' if resource_name == 'accounts'

    display_resource_name(resource_name)
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
