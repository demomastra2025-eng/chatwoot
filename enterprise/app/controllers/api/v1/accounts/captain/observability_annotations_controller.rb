# frozen_string_literal: true

class Api::V1::Accounts::Captain::ObservabilityAnnotationsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?
  before_action :set_llm_event

  def index
    render json: {
      payload: @llm_event.annotations.recent_first.map { |annotation| serialize_annotation(annotation) }
    }
  end

  def create
    annotation = @llm_event.annotations.create!(
      account: Current.account,
      user: Current.user,
      body: annotation_params[:body]
    )

    render json: { payload: serialize_annotation(annotation) }, status: :created
  end

  def destroy
    annotation = @llm_event.annotations.find(params[:id])
    annotation.destroy!

    head :no_content
  end

  private

  def set_llm_event
    @llm_event = Current.account.llm_events.where(feature: 'assistant').find(annotation_params[:event_id] || params[:event_id])
  end

  def annotation_params
    params.permit(:event_id, :body)
  end

  def serialize_annotation(annotation)
    {
      id: annotation.id,
      body: annotation.body,
      created_at: annotation.created_at,
      user: {
        id: annotation.user_id,
        name: annotation.user.name,
        email: annotation.user.email
      }
    }
  end
end
