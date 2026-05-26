class SwaggerController < ApplicationController
  def respond
    if swagger_enabled?
      swagger_root = Rails.root.join('swagger')
      file_path = swagger_root.join(derived_path).cleanpath

      return head :not_found unless file_path.to_s.start_with?("#{swagger_root}/") && file_path.file?

      render inline: file_path.read
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
    path = Rack::Utils.clean_path_info(params[:path]).delete_prefix('/')
    path << ".#{Rack::Utils.clean_path_info(params[:format]).delete_prefix('/')}" unless path.ends_with?(params[:format].to_s)
    path
  end
end
