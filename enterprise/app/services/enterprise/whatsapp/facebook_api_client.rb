module Enterprise::Whatsapp::FacebookApiClient
  def webhook_subscribed_fields(coexistence: false)
    (super + %w[calls]).uniq
  end
end
