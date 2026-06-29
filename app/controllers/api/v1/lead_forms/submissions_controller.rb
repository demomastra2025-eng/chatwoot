class Api::V1::LeadForms::SubmissionsController < ApplicationController
  before_action :set_lead_form

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid
  rescue_from ArgumentError, with: :render_unprocessable_entity
  rescue_from ::Crm::Error, with: :render_crm_error

  def create
    submission = ::LeadForms::IngestSubmissionService.new(
      lead_form: @lead_form,
      params: submission_params
    ).perform

    render json: {
      payload: {
        id: submission.id,
        status: submission.status
      }
    }, status: :created
  end

  private

  def render_crm_error(error)
    render json: { code: error.code, error: error.message, details: error.details }, status: error.status
  end

  def render_not_found(error)
    render json: { code: 'NOT_FOUND', error: error.message }, status: :not_found
  end

  def render_record_invalid(error)
    render json: {
      code: 'VALIDATION_ERROR',
      error: error.record.errors.full_messages.to_sentence,
      details: error.record.errors.to_hash(true)
    }, status: :unprocessable_content
  end

  def render_unprocessable_entity(error)
    render json: { code: 'VALIDATION_ERROR', error: error.message }, status: :unprocessable_content
  end

  def set_lead_form
    @lead_form = LeadForm.active.find_by!(public_token: params[:lead_form_token])
  end

  def submission_params
    params.except(:controller, :action, :lead_form_token).permit!.to_h
  end
end
