class Api::V1::Accounts::Captain::InboxesController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Captain::Assistant) }

  before_action :set_assistant
  def index
    @inboxes = @assistant.inboxes
  end

  def create
    raise_internal_assistant_error! if @assistant.internal_assistant?

    inbox = Current.account.inboxes.find(assistant_params[:inbox_id])
    existing_captain_inbox = CaptainInbox.find_by(inbox: inbox)

    if existing_captain_inbox&.captain_assistant_id == @assistant.id
      @captain_inbox = existing_captain_inbox
      revalidate_inbox_cache(inbox)
      render :create
      return
    end

    @captain_inbox = @assistant.captain_inboxes.build(inbox: inbox)
    @captain_inbox.save!
  rescue ActiveRecord::RecordInvalid
    @captain_inbox = CaptainInbox.find_by(inbox: inbox)
    raise unless @captain_inbox&.captain_assistant_id == @assistant.id

    revalidate_inbox_cache(inbox)
    render :create
  end

  def destroy
    @captain_inbox = @assistant.captain_inboxes.find_by!(inbox_id: permitted_params[:inbox_id])
    @captain_inbox.destroy!
    head :no_content
  end

  private

  def set_assistant
    @assistant = account_assistants.find(permitted_params[:assistant_id])
  end

  def account_assistants
    @account_assistants ||= Current.account.captain_assistants
  end

  def permitted_params
    params.permit(:assistant_id, :id, :account_id, :inbox_id)
  end

  def assistant_params
    params.require(:inbox).permit(:inbox_id)
  end

  def revalidate_inbox_cache(inbox)
    inbox.account.update_cache_key(Inbox.name.underscore)
  end

  def raise_internal_assistant_error!
    @assistant.errors.add(:usage_mode, Captain::Assistant::INTERNAL_ASSISTANT_INBOX_ERROR)
    raise ActiveRecord::RecordInvalid, @assistant
  end
end
