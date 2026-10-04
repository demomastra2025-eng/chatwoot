module Crm::Deals::UpsertEvents
  private

  def track_stage_visit!(new_record:, correlation_id:)
    if new_record
      ::Crm::StageVisits::Tracker.ensure_initial!(deal: deal, correlation_id: correlation_id)
    else
      ::Crm::StageVisits::Tracker.transition!(
        deal: deal,
        from_stage_id: deal.stage_id_before_last_save,
        correlation_id: correlation_id
      )
    end
  end

  def write_event!(new_record:, contacts_changed:, correlation_id:)
    return unless new_record || contacts_changed || filtered_previous_changes.present?

    ::Crm::Events::Writer.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: new_record ? 'deal_created' : 'deal_updated',
      meta: event_meta,
      correlation_id: correlation_id,
      command_key: new_record ? params[:idempotency_key] : nil
    )
  end

  def event_meta
    {
      changes: filtered_previous_changes,
      contact_ids: deal.deal_contacts.ordered.pluck(:contact_id),
      primary_contact_id: deal.primary_contact_id
    }
  end

  def notify_assignment!(new_record:)
    return unless new_record || deal.previous_changes.key?('owner_id')

    ::Crm::AssignmentNotificationService.new(
      account: account,
      record: deal,
      user: deal.owner,
      notification_type: 'deal_assignment',
      actor: actor
    ).perform
  end

  def realtime_event_name_for(new_record:, contacts_changed:)
    return Events::Types::CRM_DEAL_CREATED if new_record
    return Events::Types::CRM_DEAL_UPDATED if contacts_changed || filtered_previous_changes.present?
  end

  def realtime_event_meta(new_record:, contacts_changed:)
    {
      changes: filtered_previous_changes,
      contacts_changed: contacts_changed,
      event_type: new_record ? 'deal_created' : 'deal_updated'
    }
  end

  def auto_apply_default_touch_plan!
    Reminders::DefaultPlanService.new(
      account: account,
      remindable: deal,
      actor: actor
    ).perform
  end

  def sync_related_touches!
    Reminders::SyncRemindableService.new(remindable: deal).perform
  end
end
