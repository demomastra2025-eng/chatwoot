class Captain::Tools::DocumentArtifactToken
  PURPOSE = :captain_document_artifact
  DEFAULT_TTL = 2.hours
  PREFIX = 'captain_document'.freeze

  class InvalidToken < StandardError; end

  def self.encode(payload = nil, expires_in: DEFAULT_TTL, **attributes)
    payload = (payload || {}).merge(attributes)
    token = verifier.generate(payload.deep_stringify_keys, purpose: PURPOSE, expires_in: expires_in)
    "#{PREFIX}:#{token}"
  end

  def self.encoded?(token)
    token.to_s.start_with?("#{PREFIX}:")
  end

  def self.decode(token)
    raise InvalidToken, 'Invalid or expired document artifact id' unless encoded?(token)

    payload = verifier.verified(token.to_s.delete_prefix("#{PREFIX}:"), purpose: PURPOSE)
    raise InvalidToken, 'Invalid or expired document artifact id' if payload.blank?

    payload.with_indifferent_access
  end

  def self.verifier
    Rails.application.message_verifier(:captain_document_artifact)
  end
end
