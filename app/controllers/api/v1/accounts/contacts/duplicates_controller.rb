class Api::V1::Accounts::Contacts::DuplicatesController < Api::V1::Accounts::BaseController
  def index
    authorize Contact, :duplicates?
    items = Contacts::DuplicateCandidatesService.new(account: Current.account).perform
    render json: { payload: items, meta: { count: items.size } }
  end

  def dismiss
    authorize Contact, :dismiss_duplicate?
    Contacts::DuplicateCandidatesService.new(account: Current.account).dismiss!(
      contact_id: params[:contact_id],
      duplicate_contact_id: params[:duplicate_contact_id],
      user: Current.user
    )
    head :ok
  rescue ArgumentError => e
    render_could_not_create_error(e.message)
  end
end
