class LegalController < ActionController::Base
  include SwitchLocale

  around_action :switch_locale
  before_action :ensure_supported_locale
  layout 'legal'

  def terms; end

  def privacy; end

  private

  def ensure_supported_locale
    return if params[:locale].in?(%w[ru en kk])

    redirect_target = action_name == 'privacy' ? legal_privacy_path(locale: I18n.default_locale) : legal_terms_path(locale: I18n.default_locale)
    redirect_to redirect_target and return
  end
end
