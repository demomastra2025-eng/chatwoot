class SuperAdmin::AccountsController < SuperAdmin::ApplicationController
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
  # def scoped_resource
  #   if current_user.super_admin?
  #     resource_class
  #   else
  #     resource_class.with_less_stuff
  #   end
  # end

  # Override `resource_params` if you want to transform the submitted
  # data before it's persisted. For example, the following would turn all
  # empty values into nil values. It uses other APIs such as `resource_class`
  # and `dashboard`:
  #
  def resource_params
    permitted_params = super
    permitted_params[:limits] = normalize_limits(permitted_params[:limits])
    permitted_params[:selected_feature_flags] = params[:enabled_features].keys.map(&:to_sym) if params[:enabled_features].present?
    permitted_params
  end

  # See https://administrate-prototype.herokuapp.com/customizing_controller_actions
  # for more information

  def seed
    Internal::SeedAccountJob.perform_later(requested_resource)
    # rubocop:disable Rails/I18nLocaleTexts
    redirect_back(fallback_location: [namespace, requested_resource], notice: 'Account seeding triggered')
    # rubocop:enable Rails/I18nLocaleTexts
  end

  def reset_cache
    requested_resource.reset_cache_keys
    redirect_to_account(notice: 'Cache keys cleared')
  end

  def reset_captain_responses_usage
    if requested_resource.reset_response_usage
      redirect_to_account(notice: 'Captain responses usage reset')
    else
      redirect_to_account(alert: 'Unable to reset Captain responses usage')
    end
  end

  def reset_captain_tokens_usage
    if requested_resource.reset_token_usage
      redirect_to_account(notice: 'Captain tokens usage reset')
    else
      redirect_to_account(alert: 'Unable to reset Captain tokens usage')
    end
  end

  def reset_email_usage
    requested_resource.reset_email_sent_count
    redirect_to_account(notice: 'Email usage counter reset')
  end

  def destroy
    account = Account.find(params[:id])

    DeleteObjectJob.perform_later(account) if account.present?
    # rubocop:disable Rails/I18nLocaleTexts
    redirect_back(fallback_location: [namespace, requested_resource], notice: 'Account deletion is in progress.')
    # rubocop:enable Rails/I18nLocaleTexts
  end

  private

  def normalize_limits(raw_limits)
    raw_limits.to_h.each_with_object({}) do |(key, value), normalized|
      next if value.blank?

      normalized[key] = Integer(value, 10)
    rescue ArgumentError, TypeError
      normalized[key] = value
    end
  end

  def redirect_to_account(notice: nil, alert: nil)
    options = { fallback_location: [namespace, requested_resource] }
    options[:notice] = notice if notice.present?
    options[:alert] = alert if alert.present?

    # rubocop:disable Rails/I18nLocaleTexts
    redirect_back(**options)
    # rubocop:enable Rails/I18nLocaleTexts
  end
end

SuperAdmin::AccountsController.prepend_mod_with('SuperAdmin::AccountsController')
