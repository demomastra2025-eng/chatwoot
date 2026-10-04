class Crm::WorkspaceTimezone
  DEFAULT = 'Asia/Almaty'.freeze

  def self.resolve(account)
    configured = account&.reporting_timezone
    zone = ActiveSupport::TimeZone[configured] if configured.present?
    zone&.tzinfo&.identifier.presence || DEFAULT
  end
end
