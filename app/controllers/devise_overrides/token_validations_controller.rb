class DeviseOverrides::TokenValidationsController < DeviseTokenAuth::TokenValidationsController
  def validate_token
    # @resource will have been set by set_user_by_token concern
    if @resource
      @resource = preload_account_user_details(@resource)
      render 'devise/token', formats: [:json]
    else
      render_validate_token_error
    end
  end

  private

  def preload_account_user_details(user)
    includes = [:account]
    includes << :custom_role if ChatwootApp.enterprise?

    user.class.includes(account_users: includes).find(user.id)
  end
end
