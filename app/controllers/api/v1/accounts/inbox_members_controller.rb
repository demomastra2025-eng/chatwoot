class Api::V1::Accounts::InboxMembersController < Api::V1::Accounts::BaseController
  before_action :fetch_inbox
  before_action :current_agents_ids, only: [:create, :update]

  def show
    authorize @inbox, :show?
    fetch_updated_agents
  end

  def create
    authorize @inbox, :create?
    ActiveRecord::Base.transaction do
      @inbox.add_members(agents_to_be_added_ids)
    end
    fetch_updated_agents
  end

  def update
    authorize @inbox, :update?
    @inbox.add_members(Current.account.users.ids)
    fetch_updated_agents
  end

  def destroy
    authorize @inbox, :destroy?
    @inbox.add_members(Current.account.users.ids)
    head :ok
  end

  private

  def fetch_updated_agents
    @agents = Current.account.users.where(id: @inbox.members.select(:user_id))
  end

  def agents_to_be_added_ids
    requested_agents_ids - @current_agents_ids
  end

  def requested_agents_ids
    @requested_agents_ids ||= params[:user_ids].map do |user_id|
      next user_id if user_id.is_a?(Integer)
      next user_id.to_i if user_id.is_a?(String) && user_id.match?(/\A\d+\z/)

      # Invalid IDs must fail native membership validation, not be cast from a numeric prefix.
      nil
    end.uniq
  end

  def current_agents_ids
    @current_agents_ids = @inbox.members.pluck(:id)
  end

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:inbox_id])
  end
end
