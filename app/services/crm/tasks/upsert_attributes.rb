module Crm::Tasks::UpsertAttributes
  private

  def field_catalog(context_kind:)
    context = ::Crm::Task.custom_field_context_for(context_kind)
    ::Crm::FieldCatalog.new(account: account, entity_kind: 'task', context: context)
  end

  def resolve_title
    title = resolve_optional_text(:title, current: task.title)
    validation_error!('title', 'is required') if title.blank?
    title
  end

  def resolve_all_day
    return task.all_day unless params.key?(:all_day)

    ActiveModel::Type::Boolean.new.cast(params[:all_day])
  end

  def resolve_due_on
    return resolve_date(:due_on, current: task.due_on) if params.key?(:due_on)
    return if resolve_all_day && params.key?(:due_at)

    task.due_on
  end

  def resolve_schedule_timezone
    resolve_optional_text(
      :schedule_timezone,
      current: task.schedule_timezone || account.workspace_working_hours_timezone
    )
  end

  def resolve_requested_position
    return unless params.key?(:position)

    resolve_integer(:position, current: task.position, allow_nil: true)
  end
end
