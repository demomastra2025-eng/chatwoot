module PushDataHelper
  extend ActiveSupport::Concern

  def push_event_data
    Conversations::EventDataPresenter.new(self).push_data
  end

  def external_push_event_data
    Conversations::EventDataPresenter.new(self).external_push_data
  end

  def lock_event_data
    Conversations::EventDataPresenter.new(self).lock_data
  end

  def webhook_data
    Conversations::EventDataPresenter.new(self).webhook_data
  end
end
