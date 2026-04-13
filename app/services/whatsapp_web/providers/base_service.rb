class WhatsappWeb::Providers::BaseService
  pattr_initialize [:channel!]

  def provision!
    raise 'Overwrite this method in child class'
  end

  def refresh_qr!
    raise 'Overwrite this method in child class'
  end

  def reconnect!
    raise 'Overwrite this method in child class'
  end

  def disconnect!
    raise 'Overwrite this method in child class'
  end

  def repair!
    raise 'Overwrite this method in child class'
  end

  def sync_connection_state!
    raise 'Overwrite this method in child class'
  end

  def diagnostics
    raise 'Overwrite this method in child class'
  end

  def fetch_contacts(*)
    raise 'Overwrite this method in child class'
  end

  def fetch_messages(*)
    raise 'Overwrite this method in child class'
  end

  def fetch_chats(*)
    raise 'Overwrite this method in child class'
  end

  def fetch_message_by_source_id(*)
    raise 'Overwrite this method in child class'
  end

  def fetch_message_media(*)
    raise 'Overwrite this method in child class'
  end

  def prefer_provider_media_for_history?
    false
  end

  def fetch_labels
    raise 'Overwrite this method in child class'
  end

  def send_message(_message)
    raise 'Overwrite this method in child class'
  end

  def update_message(*)
    raise 'Overwrite this method in child class'
  end

  def mark_messages_read(*)
    raise 'Overwrite this method in child class'
  end

  def destroy_remote_instance!
    raise 'Overwrite this method in child class'
  end

  private

  delegate :inbox, to: :channel
end
