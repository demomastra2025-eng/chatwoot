class Api::V1::Accounts::Crm::Tasks::CommentsController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_tasks_enabled!
  before_action :set_task
  before_action :set_comment, only: [:update, :destroy]

  def index
    authorize @task

    comments = @task.comments.kept.includes(:user).ordered.limit(limit_param)
    render_payload(
      comments.map { |comment| ::Crm::PayloadBuilder.comment(comment) },
      meta: { count: comments.size }
    )
  end

  def create
    authorize @task, :update?

    comment = @task.comments.create!(
      account: Current.account,
      user: Current.user,
      body: params[:body]
    )

    render_payload(::Crm::PayloadBuilder.comment(comment), status: :created)
  end

  def update
    authorize @task, :update?

    @comment.update!(body: params[:body])
    render_payload(::Crm::PayloadBuilder.comment(@comment))
  end

  def destroy
    authorize @task, :update?

    @comment.soft_delete!
    head :ok
  end

  private

  def set_comment
    @comment = @task.comments.kept.find(params[:id])
  end

  def set_task
    @task = policy_scope(::Crm::Task).find(params[:task_id])
  end
end
