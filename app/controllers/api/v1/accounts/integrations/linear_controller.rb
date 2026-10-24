class Api::V1::Accounts::Integrations::LinearController < Api::V1::Accounts::BaseController
  before_action :fetch_conversation, only: [:create_issue, :link_issue, :unlink_issue, :linked_issues]
  before_action :fetch_hook, only: [:destroy]

  def destroy
    revoke_linear_token
    @hook.destroy!
    head :ok
  end

  def teams
    teams = linear_processor_service.teams
    if teams[:error]
      render json: { error: teams[:error] }, status: :unprocessable_content
    else
      render json: teams[:data], status: :ok
    end
  end

  def team_entities
    team_id = permitted_params[:team_id]
    team_entities = linear_processor_service.team_entities(team_id)
    if team_entities[:error]
      render json: { error: team_entities[:error] }, status: :unprocessable_content
    else
      render json: team_entities[:data], status: :ok
    end
  end

  def create_issue
    issue = linear_processor_service.create_issue(permitted_params.to_h, Current.user)
    if issue[:error]
      render json: { error: issue[:error] }, status: :unprocessable_content
    else
      Linear::ActivityMessageService.new(
        conversation: @conversation,
        action_type: :issue_created,
        issue_data: { id: issue[:data][:identifier] },
        user: Current.user
      ).perform
      render json: issue[:data], status: :ok
    end
  end

  def link_issue
    issue_id = permitted_params[:issue_id]
    title = permitted_params[:title]
    issue = linear_processor_service.link_issue(conversation_link, issue_id, title, Current.user)
    if issue[:error]
      render json: { error: issue[:error] }, status: :unprocessable_content
    else
      Linear::ActivityMessageService.new(
        conversation: @conversation,
        action_type: :issue_linked,
        issue_data: { id: issue_id },
        user: Current.user
      ).perform
      render json: issue[:data], status: :ok
    end
  end

  def unlink_issue
    link_id = permitted_params[:link_id]
    issue_id = permitted_params[:issue_id]
    issue = linear_processor_service.unlink_issue(link_id)

    if issue[:error]
      render json: { error: issue[:error] }, status: :unprocessable_content
    else
      Linear::ActivityMessageService.new(
        conversation: @conversation,
        action_type: :issue_unlinked,
        issue_data: { id: issue_id },
        user: Current.user
      ).perform
      render json: issue[:data], status: :ok
    end
  end

  def linked_issues
    results = linked_issue_links.map { |link| linear_processor_service.linked_issues(link) }
    failed = results.find { |result| result[:error] }

    if failed
      render json: { error: failed[:error] }, status: :unprocessable_content
    else
      render json: results.flat_map { |result| result[:data] }.uniq { |issue| issue['id'] }, status: :ok
    end
  end

  def search_issue
    render json: { error: 'Specify search string with parameter q' }, status: :unprocessable_content if params[:q].blank? && return

    term = params[:q]
    issues = linear_processor_service.search_issue(term)
    if issues[:error]
      render json: { error: issues[:error] }, status: :unprocessable_content
    else
      render json: issues[:data], status: :ok
    end
  end

  private

  def conversation_link
    "#{ENV.fetch('FRONTEND_URL', nil)}#{Conversations::DashboardLink.for(@conversation).path}"
  end

  # Linear finds an issue by the exact URL it was linked under. Issues linked before the account used communication
  # threads sit under the conversation URL, newer ones under the dialog URL: look under both.
  def linked_issue_links
    conversation_only = Conversations::DashboardLink.new(account_id: @conversation.account_id, conversation_display_id: @conversation.display_id)
    [Conversations::DashboardLink.for(@conversation), conversation_only].map { |link| "#{ENV.fetch('FRONTEND_URL', nil)}#{link.path}" }.uniq
  end

  def fetch_conversation
    @conversation = Current.account.conversations.find_by!(display_id: permitted_params[:conversation_id])
  end

  def linear_processor_service
    Integrations::Linear::ProcessorService.new(account: Current.account)
  end

  def permitted_params
    params.permit(:team_id, :project_id, :conversation_id, :issue_id, :link_id, :title, :description, :assignee_id, :priority, :state_id,
                  label_ids: [])
  end

  def fetch_hook
    @hook = Integrations::Hook.where(account: Current.account).find_by(app_id: 'linear')
  end

  def revoke_linear_token
    return unless @hook&.access_token

    begin
      linear_client = Linear.new(@hook.access_token, refresh_token: @hook.settings&.[]('refresh_token'))
      linear_client.revoke_token
    rescue StandardError => e
      Rails.logger.error "Failed to revoke Linear token: #{e.message}"
    end
  end
end
