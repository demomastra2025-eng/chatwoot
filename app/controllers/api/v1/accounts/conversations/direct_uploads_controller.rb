class Api::V1::Accounts::Conversations::DirectUploadsController < ActiveStorage::DirectUploadsController
  include EnsureCurrentAccountHelper
  before_action :current_account
  before_action :conversation

  def create
    return if @conversation.nil? || @current_account.nil?
    return render_storage_limit_exceeded unless storage_limit_available?

    super
  end

  private

  def conversation
    @conversation ||= Current.account.conversations.find_by(display_id: params[:conversation_id])
  end

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
