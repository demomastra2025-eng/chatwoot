class Webhooks::VkController < ActionController::API
  before_action :set_channel

  def process_payload
    if confirmation_event?
      verify_group_id!
      render plain: @channel.confirmation_token and return
    end

    verify_group_id!
    verify_secret!

    Channels::VkCommunity::ProcessWebhookEventJob.perform_later(@channel.id, request_payload.deep_stringify_keys)
    render plain: 'ok'
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Channel not found' }, status: :not_found
  rescue StandardError => e
    Rails.logger.error("[VK COMMUNITY] Webhook processing failed: #{e.message}")
    render json: { error: e.message }, status: error_status_for(e)
  end

  private

  def set_channel
    @channel = Channel::VkCommunity.find_by!(callback_id: params[:callback_id])
  end

  def confirmation_event?
    params[:type].to_s == 'confirmation'
  end

  def verify_group_id!
    raise StandardError, 'Invalid group_id' unless params[:group_id].to_i == @channel.group_id.to_i
  end

  def verify_secret!
    raise StandardError, 'Invalid secret' unless params[:secret].to_s == @channel.secret.to_s
  end

  def request_payload
    params.to_unsafe_hash.except('controller', 'action', 'callback_id').deep_symbolize_keys
  end

  def error_status_for(error)
    transient_queue_error?(error) ? :service_unavailable : :unprocessable_entity
  end

  def transient_queue_error?(error)
    exception_chain(error).any? do |exception|
      exception.class.name == ActiveJob::EnqueueError.name ||
        exception.class.name.start_with?('RedisClient::', 'Redis::')
    end
  end

  def exception_chain(error)
    [].tap do |chain|
      current = error
      while current.present? && !chain.include?(current)
        chain << current
        current = current.cause
      end
    end
  end
end
