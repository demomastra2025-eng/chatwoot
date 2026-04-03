class Api::V1::Widget::DirectUploadsController < ActiveStorage::DirectUploadsController
  include WebsiteTokenHelper
  before_action :set_web_widget
  before_action :set_contact

  def create
    return if @contact.nil? || @current_account.nil?
    return render_storage_limit_exceeded unless storage_limit_available?

    super
  end

  private

  def storage_limit_available?
    AccountLimits::StorageUsageService.new(account: @current_account).within_limit?(extra_bytes: blob_byte_size)
  end

  def blob_byte_size
    params.dig(:blob, :byte_size).to_i
  end

  def render_storage_limit_exceeded
    render json: { error: AccountLimits::StorageUsageService::LIMIT_EXCEEDED_MESSAGE }, status: :payment_required
  end
end
