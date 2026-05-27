class Api::V1::Accounts::Companies::ConversationsController < Api::V1::Accounts::Companies::BaseController
  before_action :authorize_company_read!

  def index
    conversations = Current.account.conversations.includes(
      :assignee, :contact, :inbox, :taggings
    ).where(contact_id: effective_company_contact_ids)

    @conversations = Conversations::PermissionFilterService.new(
      conversations,
      Current.user,
      Current.account
    ).perform.order(last_activity_at: :desc).limit(20)
  end

  private

  def effective_company_contact_ids
    direct_contact_ids = @company.contacts.pluck(:id)
    deal_contact_ids = Current.account.crm_deal_contacts
                              .joins(:deal)
                              .where(crm_deals: { company_id: @company.id })
                              .pluck(:contact_id)

    (direct_contact_ids + deal_contact_ids).uniq
  end
end
