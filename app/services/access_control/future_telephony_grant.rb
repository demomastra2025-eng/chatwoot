# Only identifies persisted grants written by a future Telephony release.
# The bridge does not add it to the catalog or authorize queries; the later native release owns that policy.
class AccessControl::FutureTelephonyGrant
  RESOURCE = 'telephony_calls'.freeze
  CAPABILITIES = %w[view view_reports].freeze

  def self.bridge_only?
    !AccessRoleGrant::RESOURCE_CAPABILITIES.key?(RESOURCE)
  end

  SCOPES = %w[none own team all].freeze

  def self.valid?(grant)
    grant.persisted? && grant.resource == RESOURCE && CAPABILITIES.include?(grant.capability) &&
      SCOPES.include?(grant.access_scope)
  end
end
