class Api::V1::Accounts::LeadSubmissionsController < Api::V1::Accounts::LeadForms::BaseController
  before_action :check_admin_authorization?
  before_action :set_lead_submission, only: [:show]

  def index
    submissions = Current.account.lead_submissions.includes(:lead_form, :inbox, :contact, :conversation).ordered
    submissions = submissions.where(lead_form_id: params[:lead_form_id]) if params[:lead_form_id].present?
    submissions = submissions.for_source(params[:source_kind]) if params[:source_kind].present?
    submissions = submissions.for_status(params[:status]) if params[:status].present?
    submissions = submissions.limit(limit_param)

    render_payload(
      submissions.map { |submission| ::LeadForms::PayloadBuilder.submission(submission) },
      meta: { count: submissions.size }
    )
  end

  def show
    render_payload(::LeadForms::PayloadBuilder.submission(@lead_submission))
  end

  private

  def limit_param
    requested_limit = params[:limit].presence || 20
    requested_limit.to_i.clamp(1, 100)
  end

  def set_lead_submission
    @lead_submission = Current.account.lead_submissions.find(params[:id])
  end
end
