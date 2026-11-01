class Webhooks::VkController < ActionController::API
  WebhookAuthError = Class.new(StandardError)

  rescue_from ActiveRecord::RecordNotFound do
    render json: { error: 'Channel not found' }, status: :not_found
  end

  before_action :set_channel

  def process_payload
    return render_confirmation_response if confirmation_event?

    verify_group_id!
    verify_secret!

    Channels::VkCommunity::ProcessWebhookEventJob.perform_later(@channel.id, request_payload.deep_stringify_keys)
    render plain: 'ok'
  rescue WebhookAuthError => e
    Rails.logger.warn("[VK COMMUNITY] Webhook unauthorized for channel=#{@channel&.id}: #{e.message}")
    render json: { error: 'Unauthorized' }, status: :unauthorized
  rescue StandardError => e
    Rails.logger.error("[VK COMMUNITY] Webhook processing failed (#{e.class.name}): #{e.message}")
    render json: { error: 'Webhook processing failed' }, status: error_status_for(e)
  end

  private

  def render_confirmation_response
    verify_group_id!
    verify_secret! if params.key?(:secret)
    raise WebhookAuthError, 'Missing confirmation_token' if @channel.confirmation_token.blank?

    render plain: @channel.confirmation_token
  end

  def set_channel
    @channel = Channel::VkCommunity.find_by!(callback_id: params[:callback_id])
  end

  def confirmation_event?
    params[:type].to_s == 'confirmation'
  end

  def verify_group_id!
    provided = params[:group_id].to_s.strip
    expected = @channel.group_id.to_s.strip
    return if provided.present? && expected.present? && provided.match?(/\A\d+\z/) && provided == expected

    raise WebhookAuthError, 'Invalid group_id'
  end

  def verify_secret!
    provided = params[:secret].to_s
    expected = @channel.secret.to_s
    valid = provided.present? && expected.present? &&
            provided.bytesize == expected.bytesize &&
            ActiveSupport::SecurityUtils.secure_compare(provided, expected)
    raise WebhookAuthError, 'Invalid secret' unless valid
  end

  def request_payload
    params.to_unsafe_hash.except('controller', 'action', 'callback_id', 'secret').deep_symbolize_keys
  end

  def error_status_for(error)
    transient_queue_error?(error) ? :service_unavailable : :unprocessable_entity
  end

  def transient_queue_error?(error)
    exception_chain(error).any? do |exception|
      exception.is_a?(ActiveJob::EnqueueError) ||
        exception.class.name.start_with?('RedisClient::', 'Redis::')
    end
  end

  def exception_chain(error)
    [].tap do |chain|
      current = error
      while current.present? && chain.exclude?(current)
        chain << current
        current = current.cause
      end
    end
  end
end
