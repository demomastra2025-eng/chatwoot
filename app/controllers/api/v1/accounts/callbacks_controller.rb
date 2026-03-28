class Api::V1::Accounts::CallbacksController < Api::V1::Accounts::BaseController
  FACEBOOK_FETCH_ERROR_MESSAGE = 'Failed to fetch Facebook pages. Please try again.'.freeze

  before_action :inbox, only: [:reauthorize_page]

  def register_facebook_page
    user_access_token = params[:user_access_token]
    page_access_token = params[:page_access_token]
    page_id = params[:page_id]
    inbox_name = params[:inbox_name]
    ActiveRecord::Base.transaction do
      facebook_channel = Current.account.facebook_pages.create!(
        page_id: page_id, user_access_token: user_access_token,
        page_access_token: page_access_token
      )
      @facebook_inbox = Current.account.inboxes.create!(name: inbox_name, channel: facebook_channel)
      set_instagram_id(page_access_token, facebook_channel)
      set_avatar(@facebook_inbox, page_id)
    end
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    Rails.logger.error "Error in register_facebook_page: #{e.message}"
    # Additional log statements
    log_additional_info
  end

  def log_additional_info
    Rails.logger.debug do
      "user_access_token: #{params[:user_access_token]} , page_access_token: #{params[:page_access_token]} ,
      page_id: #{params[:page_id]}, inbox_name: #{params[:inbox_name]}"
    end
  end

  def facebook_pages
    return render_facebook_error unless fb_object

    pages = []
    fb_pages = fb_object.get_connections('me', 'accounts')
    pages.concat(fb_pages)
    while fb_pages.respond_to?(:next_page) && (next_page = fb_pages.next_page)
      fb_pages = next_page
      pages.concat(fb_pages)
    end
    @page_details = mark_already_existing_facebook_pages(pages)
  rescue StandardError => e
    log_facebook_callback_error('facebook_pages', e)
    render_facebook_error
  end

  def set_instagram_id(page_access_token, facebook_channel)
    fb_object = Koala::Facebook::API.new(page_access_token)
    response = fb_object.get_connections('me', '', { fields: 'instagram_business_account' })
    return if response['instagram_business_account'].blank?

    instagram_id = response['instagram_business_account']['id']
    facebook_channel.update(instagram_id: instagram_id)
  rescue StandardError => e
    Rails.logger.error "Error in set_instagram_id: #{e.message}"
  end

  # get params[:inbox_id], current_account. params[:omniauth_token]
  def reauthorize_page
    return render_facebook_error unless fb_object

    if @inbox&.facebook?
      fb_page_id = @inbox.channel.page_id
      page_details = fb_object.get_connections('me', 'accounts')

      if (page_detail = (page_details || []).detect { |page| fb_page_id == page['id'] })
        update_fb_page(fb_page_id, page_detail['access_token'])
        render and return
      end
    end

    head :unprocessable_content
  rescue StandardError => e
    log_facebook_callback_error('reauthorize_page', e)
    render_facebook_error
  end

  private

  def inbox
    @inbox = Current.account.inboxes.find_by(id: params[:inbox_id])
  end

  def update_fb_page(fb_page_id, access_token)
    fb_page = get_fb_page(fb_page_id)
    ActiveRecord::Base.transaction do
      fb_page&.update!(user_access_token: @user_access_token, page_access_token: access_token)
      set_instagram_id(access_token, fb_page)
      fb_page&.reauthorized!
    rescue StandardError => e
      ChatwootExceptionTracker.new(e).capture_exception
      Rails.logger.error "Error in update_fb_page: #{e.message}"
    end
  end

  def get_fb_page(fb_page_id)
    Current.account.facebook_pages.find_by(page_id: fb_page_id)
  end

  def fb_object
    @user_access_token = long_lived_token(params[:omniauth_token])
    return if @user_access_token.blank?

    Koala::Facebook::API.new(@user_access_token)
  end

  def long_lived_token(omniauth_token)
    koala = Koala::Facebook::OAuth.new(GlobalConfigService.load('FB_APP_ID', ''), GlobalConfigService.load('FB_APP_SECRET', ''))
    koala.exchange_access_token_info(omniauth_token)['access_token']
  rescue StandardError => e
    log_facebook_callback_error('long_lived_token', e)
    nil
  end

  def mark_already_existing_facebook_pages(data)
    return [] if data.empty?

    data.inject([]) do |result, page_detail|
      page_detail[:exists] = Current.account.facebook_pages.exists?(page_id: page_detail['id'])
      result << page_detail
    end
  end

  def set_avatar(facebook_inbox, page_id)
    avatar_url = "https://graph.facebook.com/#{page_id}/picture?type=large"
    Avatar::AvatarFromUrlJob.perform_later(facebook_inbox, avatar_url)
  end

  def render_facebook_error(message = FACEBOOK_FETCH_ERROR_MESSAGE)
    render json: { error: message }, status: :unprocessable_content
  end

  def log_facebook_callback_error(action, error)
    ChatwootExceptionTracker.new(error).capture_exception
    Rails.logger.error "Error in #{action}: #{error.message}"
  end
end
