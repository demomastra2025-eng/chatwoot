class SwaggerController < ApplicationController
  def respond
    if swagger_enabled?
      render inline: Rails.root.join('swagger', derived_path).read
    else
      head :not_found
    end
  end

  private

  def swagger_enabled?
    return true if Rails.env.development? || Rails.env.test?

    ActiveModel::Type::Boolean.new.cast(ENV.fetch('ENABLE_SWAGGER_UI', false))
  end

  def derived_path
    params[:path] ||= 'index.html'
    path = Rack::Utils.clean_path_info(params[:path])
    path << ".#{Rack::Utils.clean_path_info(params[:format])}" unless path.ends_with?(params[:format].to_s)
    path
  end
end
