class Api::V1::Widget::DirectUploadsController < ActiveStorage::DirectUploadsController
  include WebsiteTokenHelper
  before_action :set_web_widget
  before_action :set_contact

  def create
    return if @contact.nil? || @current_account.nil?

    # Visitor uploads belong to incoming messages: the account storage limit never blocks them.
    super
  end
end
