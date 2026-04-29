module UserAuthSessions
  extend ActiveSupport::Concern

  AUTH_DEVICE_WEB_DESKTOP = Auth::SessionDeviceClassifier::WEB_DESKTOP
  AUTH_DEVICE_WEB_MOBILE = Auth::SessionDeviceClassifier::WEB_MOBILE
  AUTH_DEVICE_TYPES = [AUTH_DEVICE_WEB_DESKTOP, AUTH_DEVICE_WEB_MOBILE].freeze
  AUTH_DEVICE_CLIENT_COLUMNS = {
    AUTH_DEVICE_WEB_DESKTOP => :active_web_desktop_auth_client_id,
    AUTH_DEVICE_WEB_MOBILE => :active_web_mobile_auth_client_id
  }.freeze
  AUTH_DEVICE_SET_AT_COLUMNS = {
    AUTH_DEVICE_WEB_DESKTOP => :active_web_desktop_auth_client_set_at,
    AUTH_DEVICE_WEB_MOBILE => :active_web_mobile_auth_client_set_at
  }.freeze

  def active_auth_client?(client_id)
    client_id.to_s.present? && active_auth_client_ids.include?(client_id.to_s)
  end

  def active_auth_client_ids
    ids = AUTH_DEVICE_TYPES.filter_map { |device_type| auth_client_id_for_device(device_type).presence }
    return ids.uniq if ids.present?

    [active_auth_client_id.presence].compact
  end

  def activate_auth_client!(client_id, device_type: AUTH_DEVICE_WEB_DESKTOP)
    return if client_id.blank?

    previous_client_id = nil

    with_lock do
      normalized_client_id = client_id.to_s
      normalized_device_type = normalize_auth_device_type(device_type)
      previous_client_id = auth_client_id_for_device(normalized_device_type)

      assign_auth_client_for_device(normalized_device_type, normalized_client_id)
      self.active_auth_client_id = normalized_client_id
      self.active_auth_client_set_at = Time.current
      save!
    end

    previous_client_id if previous_client_id.present? && previous_client_id != client_id.to_s
  end

  def clear_active_auth_client!(client_id = nil)
    if client_id.blank?
      clear_all_active_auth_clients!
      return
    end

    normalized_client_id = client_id.to_s
    return unless active_auth_client?(normalized_client_id) || active_auth_client_id == normalized_client_id

    with_lock do
      clear_matching_auth_client_slots(normalized_client_id)
      sync_legacy_active_auth_client!
      self.tokens = (tokens || {}).except(normalized_client_id)
      save!
    end
  end

  def auth_session_stream_name(client_id)
    "user_session:#{id}:#{client_id}"
  end

  def broadcast_session_replaced!(client_id)
    return if client_id.blank?

    payload = {
      event: 'auth.session_replaced',
      data: { code: 'session_replaced', message: I18n.t('auth.session_replaced') }
    }

    ActionCable.server.broadcast(auth_session_stream_name(client_id), payload)
  end

  private

  def normalize_auth_device_type(device_type)
    AUTH_DEVICE_TYPES.include?(device_type.to_s) ? device_type.to_s : AUTH_DEVICE_WEB_DESKTOP
  end

  def auth_client_id_for_device(device_type)
    public_send(AUTH_DEVICE_CLIENT_COLUMNS.fetch(device_type))
  end

  def sync_legacy_active_auth_client!
    replacement_device_type = AUTH_DEVICE_TYPES.find { |device_type| auth_client_id_for_device(device_type).present? }

    self.active_auth_client_id = replacement_device_type.present? ? auth_client_id_for_device(replacement_device_type) : nil
    self.active_auth_client_set_at = nil
    return if replacement_device_type.blank?

    self.active_auth_client_set_at = public_send(AUTH_DEVICE_SET_AT_COLUMNS.fetch(replacement_device_type))
  end

  def assign_auth_client_for_device(device_type, client_id)
    public_send("#{AUTH_DEVICE_CLIENT_COLUMNS.fetch(device_type)}=", client_id)
    public_send("#{AUTH_DEVICE_SET_AT_COLUMNS.fetch(device_type)}=", client_id.present? ? Time.current : nil)
  end

  def clear_matching_auth_client_slots(client_id)
    AUTH_DEVICE_TYPES.each do |device_type|
      assign_auth_client_for_device(device_type, nil) if auth_client_id_for_device(device_type) == client_id
    end

    return unless active_auth_client_id == client_id

    self.active_auth_client_id = nil
    self.active_auth_client_set_at = nil
  end

  def clear_all_active_auth_clients!
    update!(
      active_web_desktop_auth_client_id: nil,
      active_web_desktop_auth_client_set_at: nil,
      active_web_mobile_auth_client_id: nil,
      active_web_mobile_auth_client_set_at: nil,
      active_auth_client_id: nil,
      active_auth_client_set_at: nil,
      tokens: {}
    )
  end
end
