class Captain::Tools::HttpArtifactToken
  PURPOSE = :captain_http_artifact
  DEFAULT_TTL = 2.hours

  class InvalidToken < StandardError; end

  def self.encode(payload = nil, expires_in: DEFAULT_TTL, **attributes)
    payload = (payload || {}).merge(attributes)
    verifier.generate(payload.deep_stringify_keys, purpose: PURPOSE, expires_in: expires_in)
  end

  def self.decode(token)
    payload = verifier.verified(token.to_s, purpose: PURPOSE)
    raise InvalidToken, 'Invalid or expired artifact id' if payload.blank?

    payload.with_indifferent_access
  end

  def self.verifier
    Rails.application.message_verifier(:captain_http_artifact)
  end
end
