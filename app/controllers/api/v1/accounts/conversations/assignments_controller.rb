class Api::V1::Accounts::Conversations::AssignmentsController < Api::V1::Accounts::Conversations::BaseController
  # Staff members are the only assignees; any other assignee_type is refused instead of being read as a user id.
  ASSIGNEE_TYPES = %w[User].freeze

  before_action :validate_assignee_type!, only: :create

  # assigns agent/team to a conversation
  def create
    if params.key?(:assignee_id)
      set_agent
    elsif params.key?(:team_id)
      set_team
    else
      render json: nil
    end
  end

  private

  def validate_assignee_type!
    return if params[:assignee_type].blank? || ASSIGNEE_TYPES.include?(params[:assignee_type].to_s)

    render json: { error: "assignee_type must be one of: #{ASSIGNEE_TYPES.join(', ')}" }, status: :unprocessable_content
  end

  def set_agent
    resource = Conversations::AssignmentService.new(
      conversation: @conversation,
      assignee_id: params[:assignee_id],
      assignee_type: params[:assignee_type]
    ).perform

    render_agent(resource)
  end

  def render_agent(resource)
    if resource.is_a?(User)
      render partial: 'api/v1/models/agent', formats: [:json], locals: { resource: resource }
    else
      render json: nil
    end
  end

  def set_team
    @team = Current.account.teams.find_by(id: params[:team_id])
    @conversation.update!(team: @team)
    render json: @team
  end
end
