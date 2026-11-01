module TelegramPersonal::CallErrors
  class Error < StandardError; end
  class NotRinging < Error; end
  class AlreadyAccepted < Error; end
  class NotCallOwner < Error; end
  class NotInProgress < Error; end
end
