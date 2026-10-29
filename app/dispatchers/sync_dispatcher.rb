class SyncDispatcher < BaseDispatcher
  def dispatch(event_name, timestamp, data)
    Current.without_account_user do
      event_object = Events::Base.new(event_name, timestamp, data)
      publish(event_object.method_name, event_object)
    end
  end

  def listeners
    [ActionCableListener.instance]
  end
end
