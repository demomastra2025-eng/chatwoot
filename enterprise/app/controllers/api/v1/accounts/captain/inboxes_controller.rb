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
    @captain_inbox = CaptainInbox.find_by(inbox: inbox)

    return render_existing_captain_inbox(inbox) if connected_to_current_assistant?

    @captain_inbox = @assistant.captain_inboxes.create!(captain_inbox_attributes(inbox))
  rescue ActiveRecord::RecordInvalid => e
    handle_captain_inbox_create_failure(e, inbox)
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
    params.require(:inbox).permit(:inbox_id, :auto_reply_mode)
  end

  def captain_inbox_attributes(inbox)
    {
      inbox: inbox,
      auto_reply_mode: assistant_params[:auto_reply_mode].presence
    }
  end

  def connected_to_current_assistant?
    @captain_inbox&.captain_assistant_id == @assistant.id
  end

  def render_existing_captain_inbox(inbox)
    update_requested_auto_reply_mode!
    revalidate_inbox_cache(inbox)
    render :create
  end

  def update_requested_auto_reply_mode!
    return if assistant_params[:auto_reply_mode].blank?

    @captain_inbox.update!(auto_reply_mode: assistant_params[:auto_reply_mode])
  end

  def handle_captain_inbox_create_failure(error, inbox)
    raise if error.record.errors[:auto_reply_mode].present?

    @captain_inbox = CaptainInbox.find_by(inbox: inbox)
    raise unless connected_to_current_assistant?

    render_existing_captain_inbox(inbox)
  end

  def revalidate_inbox_cache(inbox)
    inbox.account.update_cache_key(Inbox.name.underscore)
  end

  def raise_internal_assistant_error!
    @assistant.errors.add(:usage_mode, Captain::Assistant::INTERNAL_ASSISTANT_INBOX_ERROR)
    raise ActiveRecord::RecordInvalid, @assistant
  end
end
