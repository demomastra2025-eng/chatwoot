class WhatsappWeb::HistoryMediaPolicy
  AUTO_DOWNLOAD_DAYS = 90

  def self.deferred?(timestamp)
    timestamp < AUTO_DOWNLOAD_DAYS.days.ago
  end
end
