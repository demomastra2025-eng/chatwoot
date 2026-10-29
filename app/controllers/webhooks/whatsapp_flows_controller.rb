# frozen_string_literal: true

class Webhooks::WhatsappFlowsController < ActionController::API
  include MetaTokenVerifyConcern

  before_action :resolve_channel!
  before_action :verify_meta_signature!

  def process_payload
    crypto = Whatsapp::Flows::CryptoService.for_channel(@whatsapp_channel)
    decrypted = crypto.decrypt_request(parsed_body)

    response_payload = Whatsapp::Flows::DataExchangeService.new(
      channel: @whatsapp_channel,
      payload: decrypted[:payload]
    ).perform

    encrypted_body = crypto.encrypt_response(
      response_payload,
      aes_key: decrypted[:aes_key],
      initial_vector: decrypted[:initial_vector]
    )

    render plain: encrypted_body, status: :ok, content_type: 'text/plain'
  rescue Whatsapp::Flows::CryptoService::DecryptionError => e
    Rails.logger.warn("[WHATSAPP_FLOWS] decryption failed channel_id=#{@whatsapp_channel&.id} error=#{e.class}")
    head :misdirected_request
  end

  private

  def resolve_channel!
    @whatsapp_channel = Whatsapp::Flows::TokenService.resolve_channel_by_endpoint_token(params[:endpoint_token])
    return if @whatsapp_channel.present? && @whatsapp_channel.account.present?

    head :not_found
  end

  def meta_app_secrets
    [
      *channel_meta_app_secrets(@whatsapp_channel),
      GlobalConfigService.load('WHATSAPP_APP_SECRET', nil)
    ].compact_blank.uniq
  end

  def parsed_body
    body = JSON.parse(meta_request_body.to_s)
    raise Whatsapp::Flows::CryptoService::DecryptionError, 'Flow request body must be a JSON object' unless body.is_a?(Hash)

    body
  rescue JSON::ParserError
    raise Whatsapp::Flows::CryptoService::DecryptionError, 'Flow request body is not valid JSON'
  end
end
