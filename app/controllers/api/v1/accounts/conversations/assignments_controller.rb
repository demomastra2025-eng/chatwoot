class Api::V1::Accounts::Conversations::AssignmentsController < Api::V1::Accounts::Conversations::BaseController
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

  def set_agent
    resource = Conversations::AssignmentService.new(
      conversation: @conversation,
      assignee_id: params[:assignee_id]
    ).perform

    render_agent(resource)
  end

  def render_agent(resource)
    return render json: nil unless resource

    render partial: 'api/v1/models/agent', formats: [:json], locals: { resource: resource }
  end

  def set_team
    @team = Conversations::AssignmentService.new(
      conversation: @conversation,
      team_id: params[:team_id],
      actor: Current.user,
      source: 'conversation_assignment_redirect'
    ).perform
    render json: @team
  end
end
