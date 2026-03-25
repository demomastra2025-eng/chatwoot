class Api::V1::Accounts::Crm::Deals::CommentsController < Api::V1::Accounts::Crm::BaseController
  before_action :ensure_crm_deals_enabled!
  before_action :set_deal
  before_action :set_comment, only: [:update, :destroy]

  def index
    authorize @deal

    comments = @deal.comments.kept.includes(:user).ordered.limit(limit_param)
    render_payload(
      comments.map { |comment| ::Crm::PayloadBuilder.comment(comment) },
      meta: { count: comments.size }
    )
  end

  def create
    authorize @deal, :update?

    comment = @deal.comments.create!(
      account: Current.account,
      user: Current.user,
      body: params[:body]
    )

    render_payload(::Crm::PayloadBuilder.comment(comment), status: :created)
  end

  def update
    authorize @deal, :update?

    @comment.update!(body: params[:body])
    render_payload(::Crm::PayloadBuilder.comment(@comment))
  end

  def destroy
    authorize @deal, :update?

    @comment.soft_delete!
    head :ok
  end

  private

  def set_comment
    @comment = @deal.comments.kept.find(params[:id])
  end

  def set_deal
    @deal = policy_scope(::Crm::Deal).find(params[:deal_id])
  end
end
