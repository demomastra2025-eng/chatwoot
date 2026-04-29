class Auth::SessionDeviceClassifier
  WEB_DESKTOP = 'web_desktop'.freeze
  WEB_MOBILE = 'web_mobile'.freeze

  MOBILE_USER_AGENT_PATTERN = /Mobile|Android|iPhone|iPad|iPod|webOS|BlackBerry|Windows Phone|Opera Mini/i

  def self.call(user_agent)
    new(user_agent).device_type
  end

  def initialize(user_agent)
    @user_agent = user_agent.to_s
  end

  def device_type
    mobile? ? WEB_MOBILE : WEB_DESKTOP
  end

  private

  attr_reader :user_agent

  def mobile?
    user_agent.match?(MOBILE_USER_AGENT_PATTERN)
  end
end
