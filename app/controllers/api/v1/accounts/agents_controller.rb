class Api::V1::Accounts::AgentsController < Api::V1::Accounts::BaseController
  before_action :fetch_agent, except: [:create, :index, :bulk_create]
  before_action :check_authorization
  before_action :validate_limit, only: [:create]
  before_action :validate_limit_for_bulk_create, only: [:bulk_create]

  def index
    @agents = agents
  end

  def create
    builder = AgentBuilder.new(
      email: new_agent_params['email'],
      name: new_agent_params['name'],
      role: new_agent_params['role'],
      availability: new_agent_params['availability'],
      auto_offline: new_agent_params['auto_offline'],
      inviter: current_user,
      account: Current.account
    )

    @agent = builder.perform
  end

  def update
    @agent.update!(agent_params.slice(:name).compact)
    @agent.current_account_user.update!(agent_params.slice(*account_user_attributes).compact)
  end

  def destroy
    @agent.current_account_user.destroy!
    delete_user_record(@agent)
    head :ok
  end

  def bulk_create
    failures = normalized_bulk_emails.filter_map { |email| invite_bulk_agent(email) }

    if failures.any?
      render json: { errors: failures }, status: :unprocessable_content
      return
    end

    # This endpoint is used to bulk create agents during onboarding
    # onboarding_step key in present in Current account custom attributes, since this is a one time operation
    Current.account.custom_attributes.delete('onboarding_step')
    Current.account.save!
    head :ok
  end

  private

  def check_authorization
    super(User)
  end

  def fetch_agent
    @agent = agents.find(params[:id])
  end

  def account_user_attributes
    [:role, :availability, :auto_offline]
  end

  def allowed_agent_params
    [:name, :email, :role, :availability, :auto_offline]
  end

  def agent_params
    params.require(:agent).permit(allowed_agent_params)
  end

  def new_agent_params
    params.require(:agent).permit(:email, :name, :role, :availability, :auto_offline)
  end

  def agents
    @agents ||= Current.account.users.order_by_full_name.includes(:account_users, { avatar_attachment: [:blob] })
  end

  def validate_limit_for_bulk_create
    limit_available = countable_candidates(normalized_bulk_emails) <= available_agent_count

    render_payment_required('Account limit exceeded. Please purchase more licenses') unless limit_available
  end

  def validate_limit
    render_payment_required('Account limit exceeded. Please purchase more licenses') unless can_add_agent?
  end

  def available_agent_count
    [Current.account.usage_limits[:agents] - Current.account.countable_users_for_limits.count, 0].max
  end

  def can_add_agent?
    countable_candidates([new_agent_params[:email]]) <= available_agent_count
  end

  def countable_candidates(emails)
    existing_users = emails.filter_map { |email| User.from_email(email) }.uniq
    existing_count = existing_users.count do |user|
      !Current.account.account_users.exists?(user_id: user.id) && Current.account.user_countable_for_limits?(user)
    end
    new_count = emails.map { |email| email.to_s.downcase.strip }.uniq.count { |email| User.from_email(email).blank? }

    existing_count + new_count
  end

  def normalized_bulk_emails
    @normalized_bulk_emails ||= Array(params[:emails]).map { |email| email.to_s.downcase.strip }.reject(&:blank?).uniq
  end

  def existing_account_membership?(email)
    user = User.from_email(email)
    user.present? && Current.account.account_users.exists?(user_id: user.id)
  end

  def invite_bulk_agent(email, retry_on_conflict: true)
    return if existing_account_membership?(email)

    AgentBuilder.new(
      email: email,
      name: email.split('@').first,
      inviter: current_user,
      account: Current.account
    ).perform
    nil
  rescue ActiveRecord::RecordNotUnique
    return if existing_account_membership?(email)
    return invite_bulk_agent(email, retry_on_conflict: false) if retry_on_conflict

    { email: email, errors: ['Concurrent invitation could not be reconciled'] }
  rescue ActiveRecord::RecordInvalid => e
    return if existing_account_membership?(email)

    { email: email, errors: e.record.errors.full_messages }
  end

  def delete_user_record(agent)
    DeleteObjectJob.perform_later(agent) if agent.reload.account_users.blank?
  end
end

Api::V1::Accounts::AgentsController.prepend_mod_with('Api::V1::Accounts::AgentsController')
