module Captain::FirecrawlHelper
  FIRECRAWL_TOKEN_TTL = 7.days

  def generate_firecrawl_token(assistant_id, account_id, document_id: nil, import_run_id: nil)
    firecrawl_token_verifier.generate(
      {
        assistant_id: assistant_id.to_i,
        account_id: account_id.to_i,
        document_id: document_id&.to_i,
        import_run_id: import_run_id.to_s.presence
      }.compact,
      expires_in: FIRECRAWL_TOKEN_TTL,
      purpose: :captain_firecrawl_webhook
    )
  end

  def valid_firecrawl_token?(token, assistant_id:, account_id:, document_id: nil, import_run_id: nil)
    payload = firecrawl_token_verifier.verify(token, purpose: :captain_firecrawl_webhook).with_indifferent_access
    expected = {
      assistant_id: assistant_id.to_i,
      account_id: account_id.to_i,
      document_id: document_id&.to_i,
      import_run_id: import_run_id.to_s.presence
    }.compact

    payload.symbolize_keys == expected
  rescue ActiveSupport::MessageVerifier::InvalidSignature, NoMethodError
    false
  end

  private

  def firecrawl_token_verifier
    Rails.application.message_verifier(:captain_firecrawl_webhook)
  end
end
