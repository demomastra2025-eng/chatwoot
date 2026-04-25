# frozen_string_literal: true

class Confirmations::PayloadBuilder
  class << self
    def confirmation_request(request)
      {
        id: request.id,
        status: request.status,
        title: request.title,
        body: request.body,
        token: request.token,
        subject: subject_payload(request.subject),
        account_id: request.account_id,
        conversation_id: request.conversation_id,
        contact_id: request.contact_id,
        inbox_id: request.inbox_id,
        delivery_strategy: request.delivery_strategy,
        delivery_message_id: request.delivery_message_id,
        expires_at: request.expires_at&.iso8601,
        resolved_at: request.resolved_at&.iso8601,
        resolution: resolution_payload(request),
        metadata: request.metadata
      }.compact
    end

    def resolution_payload(request)
      return nil if request.resolution_source.blank? && request.resolved_at.blank?

      {
        source: request.resolution_source,
        confidence: request.resolution_confidence,
        resolved_by_id: request.resolved_by_id,
        resolved_message_id: request.resolved_message_id,
        metadata: request.resolution_metadata
      }.compact
    end

    def subject_payload(subject)
      return nil if subject.blank?

      payload = {
        type: subject.class.name,
        id: subject.id
      }
      payload[:title] = subject.title if subject.respond_to?(:title)
      payload[:name] = subject.name if subject.respond_to?(:name)
      payload[:status] = subject.status if subject.respond_to?(:status)
      payload
    end

    def action_urls(request)
      ConfirmationRequest::STATUSES.each_with_object({}) do |status, result|
        next if %w[pending expired].include?(status)

        result[status.to_sym] = confirmation_url(request, status)
      end
    end

    def confirmation_url(request, decision)
      path = "/public/confirmation_requests/#{request.token}/#{decision}"
      base_url = ENV.fetch('FRONTEND_URL', nil).presence || ENV.fetch('INSTALLATION_URL', nil).presence
      return path if base_url.blank?

      "#{base_url.to_s.chomp('/')}#{path}"
    end
  end
end
