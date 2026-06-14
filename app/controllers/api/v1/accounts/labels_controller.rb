class Api::V1::Accounts::LabelsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action :fetch_label, except: [:index, :create]
  before_action :check_authorization

  def index
    @labels = policy_scope(Current.account.labels)
    @contact_counts_by_label = contact_counts_by_label
  end

  def show; end

  def create
    @label = Current.account.labels.create!(permitted_params)
  end

  def update
    @label.update!(permitted_params)
  end

  def destroy
    @label.destroy!
    head :ok
  end

  private

  def fetch_label
    @label = Current.account.labels.find(params[:id])
  end

  def permitted_params
    params.require(:label).permit(:title, :display_title, :description, :color, :marker_type, :emoji, :show_on_sidebar)
  end

  def contact_counts_by_label
    return {} if @labels.blank?

    Current.account.contacts
           .joins(
             'INNER JOIN taggings ON taggings.taggable_id = contacts.id ' \
             "AND taggings.taggable_type = 'Contact' " \
             "AND taggings.context = 'labels'"
           )
           .joins('INNER JOIN tags ON tags.id = taggings.tag_id')
           .where(tags: { name: @labels.map(&:title) })
           .group('tags.name')
           .count('DISTINCT contacts.id')
  end
end
