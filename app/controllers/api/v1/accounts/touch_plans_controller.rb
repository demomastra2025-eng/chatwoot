class Api::V1::Accounts::TouchPlansController < Api::V1::Accounts::OutboundBaseController
  before_action :set_touch_plan, only: [:show, :update, :apply, :archive]

  def index
    authorize ReminderGroup

    touch_plans = policy_scope(ReminderGroup).kept.ordered
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

    touch_plan = Current.account.reminder_groups.new(touch_plan_params)
    touch_plan.creator ||= Current.user
    touch_plan.save!

    render_payload(Outbound::PayloadBuilder.touch_plan_payload(touch_plan), status: :created)
  end

  def update
    authorize @touch_plan

    @touch_plan.update!(touch_plan_params)
    render_payload(Outbound::PayloadBuilder.touch_plan_payload(@touch_plan))
  end

  def apply
    authorize @touch_plan, :apply?

    created_touches = Reminders::ApplyGroupService.new(
      account: Current.account,
      reminder_group: @touch_plan,
      remindable: load_remindable!,
      actor: Current.user
    ).perform

    render_payload(
      created_touches.map { |touch| Outbound::PayloadBuilder.touch_payload(touch) },
      status: :created,
      meta: { count: created_touches.size }
    )
  end

  def archive
    authorize @touch_plan, :archive?

    @touch_plan.archive!
    render_payload(Outbound::PayloadBuilder.touch_plan_payload(@touch_plan))
  end

  private

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

  # rubocop:disable Metrics/MethodLength
  def touch_plan_params
    params.permit(
      :name,
      :description,
      :active,
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
        :scheduled_at,
        :timezone,
        :body,
        :instructions,
        :auto_cancel_on_incoming,
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
