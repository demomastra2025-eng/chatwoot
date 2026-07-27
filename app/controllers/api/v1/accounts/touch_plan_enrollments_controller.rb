class Api::V1::Accounts::TouchPlanEnrollmentsController < Api::V1::Accounts::OutboundBaseController
  before_action :set_enrollment, only: [:cancel]

  def index
    authorize TouchPlanEnrollment, :index?

    render_payload(
      filtered_enrollments.map { |enrollment| Outbound::TouchPlanEnrollmentPayloadBuilder.build(enrollment) }
    )
  end

  def cancel
    authorize @enrollment, :cancel?

    @enrollment.with_lock do
      @enrollment.reload
      if @enrollment.active? || @enrollment.paused?
        @enrollment.cancel!(
          reason: params[:reason].presence || 'cancelled_by_user',
          metadata: cancellation_metadata
        )
      end
    end
    cancel_unmaterialized_reminders!

    render_payload(Outbound::TouchPlanEnrollmentPayloadBuilder.build(@enrollment.reload))
  end

  private

  def filtered_enrollments
    remindable = filtered_remindable
    return TouchPlanEnrollment.none if remindable.blank?

    policy_scope(TouchPlanEnrollment)
      .includes(:reminder_group, :remindable)
      .where(remindable: remindable, status: %w[active paused])
      .order(next_due_at: :asc, id: :asc)
  end

  def filtered_remindable
    type = params[:remindable_type].to_s
    return unless TouchPlanEnrollment::SUPPORTED_REMINDABLE_TYPES.include?(type)

    type.constantize.find_by(account_id: Current.account.id, id: params[:remindable_id])
  end

  def set_enrollment
    @enrollment = policy_scope(TouchPlanEnrollment).find(params[:id])
  end

  def cancel_unmaterialized_reminders!
    @enrollment.touch_occurrence_claims.includes(:reminder).find_each do |claim|
      claim.reminder&.cancel!('cancelled_by_touch_plan_enrollment')
    end
  end

  def cancellation_metadata
    {
      cancelled_by_type: Current.user.class.name,
      cancelled_by_id: Current.user.id
    }
  end
end
