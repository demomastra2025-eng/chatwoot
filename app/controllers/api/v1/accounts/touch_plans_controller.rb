class Api::V1::Accounts::TouchPlansController < Api::V1::Accounts::OutboundBaseController
  before_action :set_touch_plan, only: [:show, :update, :apply, :archive]

  def index
    authorize ReminderGroup

    touch_plans = filtered_touch_plans
    render_payload(
      touch_plans.map { |touch_plan| Outbound::PayloadBuilder.touch_plan_payload(touch_plan) },
      meta: { count: touch_plans.size }
    )
  end

  def show
    authorize @touch_plan

    render_payload(Outbound::PayloadBuilder.touch_plan_payload(@touch_plan))
  end

  def create
    authorize ReminderGroup

    touch_plan = Current.account.reminder_groups.new(touch_plan_attributes)
    touch_plan.creator ||= Current.user
    touch_plan.save!

    render_payload(Outbound::PayloadBuilder.touch_plan_payload(touch_plan), status: :created)
  end

  def update
    authorize @touch_plan

    @touch_plan.update!(touch_plan_attributes)
    render_payload(Outbound::PayloadBuilder.touch_plan_payload(@touch_plan))
  end

  def apply
    authorize @touch_plan, :apply?

    result = Reminders::PlanApplicationService.new(
      account: Current.account,
      reminder_group: @touch_plan,
      remindable: load_remindable!,
      actor: Current.user,
      source: 'api'
    ).perform

    render_payload(
      result.touches.map { |touch| Outbound::PayloadBuilder.touch_payload(touch) },
      status: :created,
      meta: {
        count: result.touches.size,
        execution_mode: result.execution_mode,
        enrollment_id: result.enrollment&.id,
        next_due_at: result.enrollment&.next_due_at&.iso8601
      }.compact
    )
  end

  def archive
    authorize @touch_plan, :archive?

    @touch_plan.archive!
    render_payload(Outbound::PayloadBuilder.touch_plan_payload(@touch_plan))
  end

  private

  def filtered_touch_plans
    scope = policy_scope(ReminderGroup).kept
    if params[:assistant_id].present?
      assistant = load_assistant!(params[:assistant_id])
      scope = scope.for_assistant_workspace(assistant.id)
    end

    scope.ordered
  end

  def load_remindable!
    type = params.require(:remindable_type).to_s
    id = params.require(:remindable_id)
    klass = type.safe_constantize

    raise ArgumentError, 'Unsupported remindable_type' unless account_scoped_model?(klass)

    scope = klass.where(account_id: Current.account.id)
    if display_id_reference?(klass)
      scope.find_by(display_id: id) || scope.find(id)
    else
      scope.find(id)
    end
  end

  def account_scoped_model?(klass)
    klass.is_a?(Class) && klass < ApplicationRecord && klass.column_names.include?('account_id')
  end

  def display_id_reference?(klass)
    [Conversation, CommunicationThread].include?(klass)
  end

  def set_touch_plan
    @touch_plan = policy_scope(ReminderGroup).find(params[:id])
  end

  def touch_plan_attributes
    attrs = touch_plan_params.to_h.symbolize_keys
    attrs[:assistant] = load_assistant!(attrs.delete(:assistant_id)) if attrs.key?(:assistant_id)
    attrs
  end

  def load_assistant!(assistant_id)
    return nil if assistant_id.blank?

    Current.account.captain_assistants.find(assistant_id)
  end

  # rubocop:disable Metrics/MethodLength
  def touch_plan_params
    params.permit(
      :name,
      :description,
      :active,
      :assistant_id,
      entity_kinds: [],
      touches: [
        :action_type,
        :content_kind,
        :text_mode,
        :timing_mode,
        :repeat_mode,
        :repeat_until_at,
        :relative_anchor,
        :relative_offset_seconds,
        :relative_time_mode,
        :relative_time_of_day,
        :manual_schedule_override,
        :scheduled_at,
        :timezone,
        :body,
        :instructions,
        :auto_cancel_on_incoming,
        :post_delivery_action,
        :target_inbox_id,
        :target_contact_id,
        :target_contact_inbox_id,
        :target_conversation_id,
        { attachments: [], template_params: {}, metadata: {} }
      ]
    )
  end
  # rubocop:enable Metrics/MethodLength
end
