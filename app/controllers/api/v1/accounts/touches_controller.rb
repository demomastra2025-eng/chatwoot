class Api::V1::Accounts::TouchesController < Api::V1::Accounts::OutboundBaseController
  before_action :set_touch, only: [:show, :update, :destroy, :approve, :cancel]

  def index
    authorize Reminder

    touches = filtered_touches
    render_payload(
      touches.map { |touch| Outbound::PayloadBuilder.touch_payload(touch) },
      meta: { count: touches.size }
    )
  end

  def show
    authorize @touch

    render_payload(Outbound::PayloadBuilder.touch_payload(@touch))
  end

  def create
    authorize Reminder

    touch = Current.account.reminders.new(touch_attributes)
    touch.creator ||= Current.user
    touch.save!
    touch.approve! if touch.draft? && touch.ready_for_pending?

    render_payload(Outbound::PayloadBuilder.touch_payload(touch), status: :created)
  end

  def update
    authorize @touch

    @touch.update!(touch_attributes)
    @touch.approve! if @touch.draft? && @touch.ready_for_pending?
    render_payload(Outbound::PayloadBuilder.touch_payload(@touch))
  end

  def destroy
    authorize @touch, :destroy?

    unless @touch.destroyable?
      render json: { error: 'Only unsent delayed messages can be deleted.' }, status: :unprocessable_entity
      return
    end

    @touch.destroy!
    head :ok
  end

  def approve
    authorize @touch, :approve?

    @touch.approve!
    render_payload(Outbound::PayloadBuilder.touch_payload(@touch))
  end

  def cancel
    authorize @touch, :cancel?

    @touch.cancel!(params[:reason])
    render_payload(Outbound::PayloadBuilder.touch_payload(@touch))
  end

  private

  # rubocop:disable Metrics/AbcSize
  def filtered_touches
    scope = policy_scope(Reminder).includes(
      :remindable,
      :conversation,
      :target_contact,
      :target_conversation,
      :target_inbox
    ).ordered
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(action_type: params[:action_type]) if params[:action_type].present?
    scope = scope.where(owner_id: params[:owner_id]) if params[:owner_id].present?
    scope = scope.where(remindable_type: params[:remindable_type]) if params[:remindable_type].present?
    if params[:remindable_id].present?
      scope = if params[:remindable_type].present?
                remindable = resolve_remindable_reference(params[:remindable_type], params[:remindable_id])
                remindable.present? ? scope.where(remindable_id: remindable.id) : scope.none
              else
                scope.where(remindable_id: params[:remindable_id])
              end
    end
    if params[:conversation_id].present?
      conversation = resolve_conversation_reference(params[:conversation_id])
      scope = conversation.present? ? scope.where(conversation_id: conversation.id) : scope.none
    end
    scope
  end
  # rubocop:enable Metrics/AbcSize

  def set_touch
    @touch = policy_scope(Reminder).find(params[:id])
  end

  def touch_attributes
    attrs = touch_params.to_h.symbolize_keys
    attrs[:conversation_id] = resolve_conversation_reference!(attrs[:conversation_id]).id if attrs[:conversation_id].present?
    attrs[:target_conversation_id] = resolve_conversation_reference!(attrs[:target_conversation_id]).id if attrs[:target_conversation_id].present?
    attrs[:manual_schedule_override] = true if manual_schedule_override_update?(attrs)

    if params[:remindable_type].present? || params[:remindable_id].present?
      attrs.delete(:remindable_type)
      attrs.delete(:remindable_id)
      attrs[:remindable] = load_remindable!
    end

    attrs
  end

  def load_remindable!
    type = params.require(:remindable_type).to_s
    id = params.require(:remindable_id)
    klass = type.safe_constantize

    raise ArgumentError, 'Unsupported remindable_type' unless account_scoped_model?(klass)

    resolve_account_scoped_reference!(klass, id)
  end

  def resolve_remindable_reference(type, value)
    klass = type.to_s.safe_constantize
    return unless account_scoped_model?(klass)

    resolve_account_scoped_reference(klass, value)
  end

  def account_scoped_model?(klass)
    klass.is_a?(Class) && klass < ApplicationRecord && klass.column_names.include?('account_id')
  end

  def resolve_account_scoped_reference!(klass, value)
    resolve_account_scoped_reference(klass, value) ||
      raise(ActiveRecord::RecordNotFound, "Couldn't find #{klass.name} for current account")
  end

  def resolve_account_scoped_reference(klass, value)
    scope = klass.where(account_id: Current.account.id)
    return scope.find_by(display_id: value) || scope.find_by(id: value) if display_id_reference?(klass)

    scope.find_by(id: value)
  end

  def display_id_reference?(klass)
    [Conversation, CommunicationThread].include?(klass)
  end

  def resolve_conversation_reference(value)
    return if value.blank?

    Current.account.conversations.find_by(display_id: value) ||
      Current.account.conversations.find_by(id: value)
  end

  def resolve_conversation_reference!(value)
    resolve_conversation_reference(value) ||
      raise(
        ActiveRecord::RecordNotFound,
        "Couldn't find Conversation for current account"
      )
  end

  def manual_schedule_override_update?(attrs)
    return false if @touch.blank?
    return false unless @touch.relative?
    return false unless attrs.key?(:scheduled_at)
    return false if ActiveModel::Type::Boolean.new.cast(attrs[:manual_schedule_override])

    attrs[:scheduled_at].present? && attrs[:scheduled_at].to_s != @touch.scheduled_at&.iso8601
  end

  # rubocop:disable Metrics/MethodLength
  def touch_params
    params.permit(
      :owner_id,
      :conversation_id,
      :remindable_type,
      :remindable_id,
      :reminder_group_id,
      :status,
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
      :target_inbox_id,
      :target_contact_id,
      :target_contact_inbox_id,
      :target_conversation_id,
      attachments: [],
      template_params: {},
      metadata: {}
    )
  end
  # rubocop:enable Metrics/MethodLength
end
