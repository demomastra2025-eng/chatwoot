class AsyncDispatcher < BaseDispatcher
  def dispatch(event_name, timestamp, data)
    job = if Telephony::RealtimeEventQueue.telephony?(event_name, data)
            EventDispatcherJob.set(queue: :telephony_realtime)
          else
            EventDispatcherJob
          end
    job.perform_later(event_name, timestamp, data)
  end

  def publish_event(event_name, timestamp, data)
    event_object = Events::Base.new(event_name, timestamp, data)
    publish(event_object.method_name, event_object)
  end

  def listeners
    [
      AutomationRuleListener.instance,
      CampaignListener.instance,
      CrmAutomationRuleListener.instance,
      CsatSurveyListener.instance,
      HookListener.instance,
      InstallationWebhookListener.instance,
      NotificationListener.instance,
      ParticipationListener.instance,
      RemindersListener.instance,
      ReportingEventListener.instance,
      SchedulingAutomationRuleListener.instance,
      WhatsappTypingListener.instance,
      WebhookListener.instance
    ]
  end
end

AsyncDispatcher.prepend_mod_with('AsyncDispatcher')
