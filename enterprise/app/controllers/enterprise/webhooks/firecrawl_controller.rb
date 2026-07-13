class Enterprise::Webhooks::FirecrawlController < ActionController::API
  MAX_REQUEST_BYTES = ENV.fetch('FIRECRAWL_WEBHOOK_MAX_BYTES', 10.megabytes).to_i.clamp(1.megabyte, 25.megabytes)
  MAX_PAGE_EVENTS = ENV.fetch('FIRECRAWL_WEBHOOK_MAX_PAGE_EVENTS', 100).to_i.clamp(1, 500)

  before_action :validate_request_size!
  before_action :validate_request!

  def process_payload
    return head :conflict if import_job_binding_pending?
    return head :ok if stale_import_event?
    return render_payload_too_large if page_event? && page_payloads.size > MAX_PAGE_EVENTS

    process_page_events if page_event?
    process_terminal_events if terminal_event?

    head :ok
  end

  private

  include Captain::FirecrawlHelper

  def process_page_events
    return if requested_source_document_unavailable?

    page_payloads.each do |payload|
      unless payload.respond_to?(:with_indifferent_access)
        source_document&.mark_import_failed!('Firecrawl page event payload is invalid', import_run_id: import_run_id)
        next
      end

      page_url = page_url_for(payload)
      if page_url.blank?
        source_document&.mark_import_failed!('Firecrawl page event is missing URL', import_run_id: import_run_id)
        next
      end
      next if source_document.present? && !source_document.expected_import_url?(page_url)

      if payload.with_indifferent_access[:markdown].to_s.bytesize > Captain::Tools::FirecrawlParserJob::MAX_MARKDOWN_BYTES
        source_document&.record_failed_urls!([page_url], import_run_id: import_run_id)
        next
      end

      source_document&.mark_page_received!(page_url, import_run_id: import_run_id)
      parser_job_args = {
        assistant_id: assistant.id,
        payload: payload,
        source_document_id: source_document&.id,
        import_run_id: import_run_id
      }
      parser_job_args[:job_id] = request_payload['id'] if source_document.present?
      Captain::Tools::FirecrawlParserJob.perform_later(**parser_job_args)
    end
  end

  def process_terminal_events
    return if source_document.blank?

    if started_event?
      source_document.mark_import_processing!(import_run_id: import_run_id)
      return
    end

    Captain::Documents::FinalizeImportJob.set(wait: 5.seconds).perform_later(
      document_id: source_document.id,
      event_type: event_type,
      job_id: request_payload['id'],
      error_message: error_message,
      import_run_id: import_run_id
    )
  end

  def assistant
    @assistant ||= Captain::Assistant.find(params[:assistant_id])
  end

  def source_document
    @source_document ||= assistant.account.captain_documents.visible_to_assistant(assistant.id).find_by(id: params[:document_id])
  end

  def requested_source_document_unavailable?
    params[:document_id].present? && source_document.blank?
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
      parsed_payload = body.present? ? JSON.parse(body) : {}
      parsed_payload.is_a?(Hash) ? parsed_payload : {}
    rescue JSON::ParserError
      {}
    end
  end

  def validate_request_size!
    return if request.content_length.to_i <= MAX_REQUEST_BYTES && request.raw_post.bytesize <= MAX_REQUEST_BYTES

    render_payload_too_large
  end

  def validate_request!
    return if signed_token_valid? && signature_absent_or_valid?

    render json: { error: 'Invalid webhook signature' }, status: :unauthorized
  end

  def signed_token_valid?
    return false if params[:token].blank?

    valid_firecrawl_token?(
      params[:token],
      assistant_id: params[:assistant_id],
      account_id: assistant.account_id,
      document_id: params[:document_id],
      import_run_id: params[:import_run_id]
    )
  rescue ActiveRecord::RecordNotFound
    false
  end

  def signature_absent_or_valid?
    request.headers['X-Firecrawl-Signature'].blank? || signature_valid?
  end

  def signature_valid?
    return false if webhook_secret.blank?

    signature = request.headers['X-Firecrawl-Signature'].to_s
    return false if signature.blank?

    expected_signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', webhook_secret, request.raw_post)}"
    return false unless expected_signature.bytesize == signature.bytesize

    ActiveSupport::SecurityUtils.secure_compare(expected_signature, signature)
  end

  def webhook_secret
    ENV['FIRECRAWL_WEBHOOK_SECRET'].presence
  end

  def error_message
    request_payload['error'].presence ||
      request_payload['message'].presence ||
      'Firecrawl import failed'
  end

  def import_run_id
    params[:import_run_id].presence
  end

  def stale_import_event?
    return false if source_document.blank?
    return true unless source_document.current_import_run?(import_run_id)
    return true if request_payload['id'].blank?

    source_document.import_job_id.blank? || source_document.import_job_id.to_s != request_payload['id'].to_s
  end

  def import_job_binding_pending?
    return false if source_document.blank? || request_payload['id'].blank?
    return false unless source_document.current_import_run?(import_run_id)
    return false unless source_document.in_progress?

    source_document.import_job_id.blank?
  end

  def page_url_for(payload)
    metadata = payload.with_indifferent_access[:metadata] || {}
    metadata[:url].presence || metadata[:sourceURL].presence || metadata[:ogUrl].presence
  end

  def render_payload_too_large
    render json: { error: 'Webhook payload is too large' }, status: :content_too_large
  end
end
