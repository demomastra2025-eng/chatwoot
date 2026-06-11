module Enterprise::Whatsapp::FacebookApiClient
  def webhook_subscribed_fields
    (super + %w[calls]).uniq
  end
end
