class SuperAdmin::PlatformBannersController < SuperAdmin::ApplicationController
  before_action :ensure_onelink_cloud

  private

  def ensure_onelink_cloud
    raise ActionController::RoutingError, 'Not Found' unless ChatwootApp.chatwoot_cloud?
  end
end
