class Enterprise::Webhooks::FirecrawlController < ActionController::API
  before_action :validate_request!

  def process_payload
    process_page_events if page_event?
    process_terminal_events if terminal_event?

    head :ok
  end

  private

  include Captain::FirecrawlHelper

  def process_page_events
    page_payloads.each do |payload|
      Captain::Tools::FirecrawlParserJob.perform_later(
        assistant_id: assistant.id,
        payload: payload,
        source_document_id: source_document&.id
      )
    end
  end

  def process_terminal_events
    return if source_document.blank?

    if started_event?
      source_document.mark_import_processing!
      return
    end

    Captain::Documents::FinalizeImportJob.perform_later(
      document_id: source_document.id,
      event_type: event_type,
      job_id: request_payload['id'],
      error_message: error_message
    )
  end

  def assistant
    @assistant ||= Captain::Assistant.find(params[:assistant_id])
  end

  def source_document
    @source_document ||= assistant.account.captain_documents.find_by(id: params[:document_id])
  end

  def event_type
    request_payload['type'].presence || params[:type]
  end

  def page_event?
    event_type.to_s.end_with?('.page')
  end

  def started_event?
    event_type.to_s.end_with?('.started')
  end

  def completed_event?
    event_type.to_s.end_with?('.completed')
  end

  def failed_event?
    event_type.to_s.end_with?('.failed')
  end

  def terminal_event?
    started_event? || completed_event? || failed_event?
  end

  def page_payloads
    data = request_payload['data']
    return [] if data.blank?

    data.is_a?(Array) ? data : [data]
  end

  def request_payload
    @request_payload ||= begin
      body = request.raw_post
      body.present? ? JSON.parse(body) : {}
    rescue JSON::ParserError
      {}
    end
  end

  def validate_request!
    return if signature_valid?
    return if legacy_token_valid?

    render json: { error: 'Invalid webhook signature' }, status: :unauthorized
  end

  def legacy_token_valid?
    return false if params[:token].blank?
    return false if assistant_token.blank?
    return false unless assistant_token.to_s.bytesize == params[:token].to_s.bytesize

    ActiveSupport::SecurityUtils.secure_compare(assistant_token.to_s, params[:token].to_s)
  rescue ActiveRecord::RecordNotFound
    false
  end

  def signature_valid?
    return false if webhook_secret.blank?

    signature = request.headers['X-Firecrawl-Signature'].to_s
    return false if signature.blank?

    expected_signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', webhook_secret, request.raw_post)}"
    return false unless expected_signature.bytesize == signature.bytesize

    ActiveSupport::SecurityUtils.secure_compare(expected_signature, signature)
  end

  def assistant_token
    generate_firecrawl_token(assistant.id, assistant.account_id)
  end

  def webhook_secret
    ENV['FIRECRAWL_WEBHOOK_SECRET'].presence
  end

  def error_message
    request_payload['error'].presence ||
      request_payload['message'].presence ||
      'Firecrawl import failed'
  end
end
