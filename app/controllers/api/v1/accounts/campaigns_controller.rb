class Api::V1::Accounts::CampaignsController < Api::V1::Accounts::BaseController
  before_action :campaign, except: [:index, :create, :preview]
  before_action :check_authorization

  def index
    @campaigns = Current.account.campaigns.includes(:sender, :captain_assistant, :inbox, :campaign_runs)
  end

  def show; end

  def create
    @campaign = Current.account.campaigns.create!(campaign_params)
  end

  def update
    @campaign.update!(campaign_params)
  end

  def destroy
    @campaign.destroy!
    head :ok
  end

  def analytics
    render json: Campaigns::AnalyticsService.new(campaign: @campaign).call
  end

  def preview
    inbox = Current.account.inboxes.find(permitted_campaign_params[:inbox_id])

    render json: Campaigns::PreviewService.new(
      account: Current.account,
      inbox: inbox,
      audience: permitted_campaign_params[:audience],
      message: permitted_campaign_params[:message],
      instructions: permitted_campaign_params[:instructions],
      text_mode: permitted_campaign_params[:text_mode],
      template_params: permitted_campaign_params[:template_params]
    ).call
  end

  def retry_failed
    Campaigns::RetryFailedDeliveriesService.new(campaign: @campaign).perform
    @campaign.reload

    render json: Campaigns::AnalyticsService.new(campaign: @campaign).call
  end

  def cancel
    @campaign.cancel_one_off!
    render :show
  end

  def restart
    Campaigns::RestartService.new(campaign: @campaign).perform
    @campaign.reload

    render json: Campaigns::AnalyticsService.new(campaign: @campaign).call
  end

  def resume
    Campaigns::ResumeService.new(campaign: @campaign).perform
    @campaign.reload

    render json: Campaigns::AnalyticsService.new(campaign: @campaign).call
  end

  private

  def campaign
    @campaign ||= Current.account.campaigns.find_by!(display_id: params[:id])
  end

  def permitted_campaign_params
    params.fetch(:campaign, params).permit(
      :title, :description, :message, :instructions, :text_mode, :enabled, :trigger_only_during_business_hours, :inbox_id, :sender_id,
      :captain_assistant_id, :scheduled_at,
      audience: [:type, :id], trigger_rules: {}, template_params: {}
    )
  end

  def campaign_params
    permitted_campaign_params.tap do |campaign_attributes|
      assign_default_sender_for_create(campaign_attributes)
    end
  end

  def assign_default_sender_for_create(campaign_attributes)
    return unless action_name == 'create'
    return if Current.user.blank?
    return if campaign_attributes.key?(:sender_id) || campaign_attributes.key?('sender_id')

    campaign_attributes[:sender_id] = Current.user.id
  end
end
